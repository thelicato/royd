// Optional host-side Android 15 measurement tool. Never installed in an image.
package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const ownerLabel = "org.royd.measure.owner"

type config struct {
	Image, Output, Socket, PostCheck string
	CPUs, Width, Height, DPI         int
	MemoryBytes                      int64
	BootTimeout, StartupDelay        time.Duration
	Settle                           time.Duration
	Launches, Cycles                 int
	Privileged                       bool
	AndroidArgs                      []string
}

func defaults() config {
	return config{Socket: "/var/run/docker.sock", CPUs: 4, MemoryBytes: 4 << 30,
		Width: 540, Height: 960, DPI: 240, BootTimeout: 180 * time.Second,
		StartupDelay: 10 * time.Second, Settle: 10 * time.Second, Launches: 5, Cycles: 5}
}

func (c config) validate() error {
	if !regexp.MustCompile(`^sha256:[a-f0-9]{64}$`).MatchString(c.Image) {
		return errors.New("image must be an explicit local sha256 image ID, not a mutable tag")
	}
	if c.Output == "" || !filepath.IsAbs(c.Socket) || filepath.Clean(c.Socket) != c.Socket || !c.Privileged {
		return errors.New("a fresh output directory, absolute local Docker socket and explicit --privileged acknowledgement are required")
	}
	if c.CPUs < 1 || c.CPUs > 1024 || c.MemoryBytes < 256<<20 || c.MemoryBytes > 1<<50 ||
		c.Width < 64 || c.Width > 8192 || c.Height < 64 || c.Height > 8192 || c.DPI < 1 || c.DPI > 2000 ||
		c.Launches < 1 || c.Launches > 100 || c.Cycles < 1 || c.Cycles > 100 ||
		c.BootTimeout < time.Second || c.BootTimeout > 30*time.Minute ||
		c.StartupDelay < time.Second || c.StartupDelay >= c.BootTimeout || c.Settle < 0 || c.Settle > time.Minute {
		return errors.New("measurement limits, dimensions, counts or durations are out of range")
	}
	if c.PostCheck != "" && !filepath.IsAbs(c.PostCheck) {
		return errors.New("post-check must be an absolute trusted host executable path")
	}
	return nil
}

type launch struct {
	TotalTimeMS int64   `json:"android_total_time_ms"`
	WallMS      float64 `json:"host_command_wall_ms"`
}

type metrics struct {
	ObservedHomeMS *float64 `json:"docker_start_to_observed_home_ms"`
	ColdLaunches   []launch `json:"cold_settings_launches"`
	Frames         *int64   `json:"settings_frames"`
	JankyFrames    *int64   `json:"settings_janky_frames"`
	FrameP50MS     *int64   `json:"settings_frame_p50_ms"`
	FrameP90MS     *int64   `json:"settings_frame_p90_ms"`
	CPUUsec        *int64   `json:"container_workload_cpu_usage_usec"`
	SettledBytes   *int64   `json:"settled_container_memory_bytes"`
	PeakBytes      *int64   `json:"container_lifetime_peak_before_postcheck_bytes"`
}

type result struct {
	Format        int               `json:"format"`
	Workload      string            `json:"workload"`
	Status        string            `json:"status"`
	Phase         string            `json:"phase"`
	Error         string            `json:"error,omitempty"`
	Qualification string            `json:"post_check_status"`
	Comparability string            `json:"comparability"`
	Started       string            `json:"started_at"`
	Finished      string            `json:"finished_at"`
	Config        config            `json:"config"`
	Container     string            `json:"container_id,omitempty"`
	SystemServer  string            `json:"system_server_pid,omitempty"`
	DockerStarted string            `json:"docker_started_at,omitempty"`
	Volume        string            `json:"volume"`
	Metrics       metrics           `json:"metrics"`
	Evidence      map[string]string `json:"evidence"`
	Unmeasured    []string          `json:"unmeasured"`
}

type containerInfo struct {
	ID, Image string
	Config    struct{ Labels map[string]string }
	State     struct {
		Running, OOMKilled bool
		StartedAt          string
	}
	RestartCount int
	HostConfig   struct {
		NanoCpus, Memory, MemorySwap int64
		Privileged                   bool
		CgroupnsMode                 string
	}
	Mounts []struct{ Type, Name, Destination string }
}

type volumeInfo struct {
	Name, CreatedAt string
	Labels          map[string]string
}

type runCommand func(context.Context, string, []string, io.Writer, io.Writer) error

type harness struct {
	cfg                                  config
	run                                  runCommand
	now                                  func() time.Time
	sleep                                func(context.Context, time.Duration) error
	owner, name, volume, volumeCreatedAt string
	mayHaveContainer, mayHaveVolume      bool
	sequence                             int
	journal                              *os.File
	result                               result
}

func cleanEnvironment(socket string) []string {
	var env []string
	for _, item := range os.Environ() {
		if !strings.HasPrefix(item, "DOCKER_HOST=") && !strings.HasPrefix(item, "DOCKER_CONTEXT=") {
			env = append(env, item)
		}
	}
	return append(env, "DOCKER_HOST=unix://"+socket)
}

func execute(socket string) runCommand {
	return func(ctx context.Context, name string, args []string, stdout, stderr io.Writer) error {
		cmd := exec.CommandContext(ctx, name, args...)
		cmd.Env = cleanEnvironment(socket)
		cmd.Stdout, cmd.Stderr = stdout, stderr
		// Bound trusted post-check descendants too, not only their shell/CLI.
		cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
		cmd.Cancel = func() error {
			err := syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
			if errors.Is(err, syscall.ESRCH) {
				return os.ErrProcessDone
			}
			return err
		}
		cmd.WaitDelay = 2 * time.Second
		return cmd.Run()
	}
}

func sleepContext(ctx context.Context, d time.Duration) error {
	timer := time.NewTimer(d)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}

// Output files are exclusive, including on command failure. Full logs stream to
// disk; only small outputs needed for parsing are subsequently read into memory.
func (h *harness) command(ctx context.Context, label string, limit time.Duration, parse bool, name string, args ...string) ([]byte, error) {
	h.sequence++
	base := fmt.Sprintf("commands/%03d-%s", h.sequence, label)
	out, err := os.OpenFile(filepath.Join(h.cfg.Output, base+".stdout"), os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return nil, err
	}
	defer out.Close()
	stderr, err := os.OpenFile(filepath.Join(h.cfg.Output, base+".stderr"), os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return nil, err
	}
	defer stderr.Close()
	h.result.Evidence[label] = base + ".stdout"
	started := h.now()
	bounded, cancel := context.WithTimeout(ctx, limit)
	defer cancel()
	commandErr := h.run(bounded, name, args, out, stderr)
	entry := struct {
		Name, Started, Stdout, Stderr, Error string
		Args                                 []string
		ElapsedMS                            float64
	}{Name: name, Args: args, Started: started.UTC().Format(time.RFC3339Nano),
		Stdout: base + ".stdout", Stderr: base + ".stderr", ElapsedMS: milliseconds(h.now().Sub(started))}
	if commandErr != nil {
		entry.Error = commandErr.Error()
	}
	if err := json.NewEncoder(h.journal).Encode(entry); err != nil {
		return nil, err
	}
	if commandErr != nil {
		return nil, fmt.Errorf("%s failed: %w (see %s)", label, commandErr, base)
	}
	if !parse {
		return nil, nil
	}
	info, err := out.Stat()
	if err != nil {
		return nil, err
	}
	if info.Size() > 8<<20 {
		return nil, fmt.Errorf("%s output exceeds the parsing limit; full output retained", label)
	}
	return os.ReadFile(out.Name())
}

func (h *harness) docker(ctx context.Context, label string, args ...string) ([]byte, error) {
	return h.command(ctx, label, 30*time.Second, true, "docker", append([]string{"--host", "unix://" + h.cfg.Socket}, args...)...)
}

func (h *harness) android(ctx context.Context, label string, args ...string) ([]byte, error) {
	return h.docker(ctx, label, append([]string{"exec", h.result.Container, "timeout", "25"}, args...)...)
}

func milliseconds(d time.Duration) float64 { return float64(d) / float64(time.Millisecond) }

func (h *harness) inspect(ctx context.Context, label, target string) (containerInfo, error) {
	var items []containerInfo
	data, err := h.docker(ctx, label, "inspect", target)
	if err == nil {
		err = json.Unmarshal(data, &items)
	}
	if err != nil {
		return containerInfo{}, err
	}
	if len(items) != 1 || items[0].ID == "" || items[0].Config.Labels[ownerLabel] != h.owner || items[0].Image != h.cfg.Image {
		return containerInfo{}, errors.New("container identity, image or ownership changed")
	}
	if h.result.Container != "" && items[0].ID != h.result.Container {
		return containerInfo{}, errors.New("container ID changed")
	}
	return items[0], nil
}

func (h *harness) inspectVolume(ctx context.Context, label string) (volumeInfo, error) {
	var items []volumeInfo
	data, err := h.docker(ctx, label, "volume", "inspect", h.volume)
	if err == nil {
		err = json.Unmarshal(data, &items)
	}
	if err != nil {
		return volumeInfo{}, err
	}
	if len(items) != 1 || items[0].Name != h.volume || items[0].Labels[ownerLabel] != h.owner || items[0].CreatedAt == "" ||
		(h.volumeCreatedAt != "" && items[0].CreatedAt != h.volumeCreatedAt) {
		return volumeInfo{}, errors.New("volume identity or ownership changed; refusing adoption or deletion")
	}
	return items[0], nil
}

func (h *harness) finish(cause error) error {
	// Use a separate bounded context so interruption cannot discard evidence or
	// turn ownership checks into unconditional name-based deletion.
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	if h.mayHaveContainer {
		info, err := h.inspect(ctx, "container-inspect", h.name)
		if err == nil {
			h.result.Container = info.ID
			_, err = h.command(ctx, "container-log", 30*time.Second, false, "docker", "--host", "unix://"+h.cfg.Socket, "logs", "--timestamps", info.ID)
			cause = errors.Join(cause, err)
			_, err = h.docker(ctx, "container-cleanup", "rm", "-f", "-v", info.ID)
			cause = errors.Join(cause, err)
		} else if h.result.Container != "" || cause == nil {
			cause = errors.Join(cause, err)
		}
	}
	if h.mayHaveVolume {
		_, err := h.inspectVolume(ctx, "volume-final-inspect")
		if err == nil {
			_, err = h.docker(ctx, "volume-cleanup", "volume", "rm", h.volume)
			cause = errors.Join(cause, err)
		} else if h.volumeCreatedAt != "" || cause == nil {
			cause = errors.Join(cause, err)
		}
	}
	cause = errors.Join(cause, h.journal.Close())
	if cause != nil {
		h.result.Status, h.result.Error = "fail", cause.Error()
	} else {
		h.result.Status, h.result.Phase = "pass", "complete"
	}
	h.result.Finished = h.now().UTC().Format(time.RFC3339Nano)
	f, err := os.OpenFile(filepath.Join(h.cfg.Output, "result.json"), os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err == nil {
		err = json.NewEncoder(f).Encode(h.result)
		err = errors.Join(err, f.Close())
	}
	return errors.Join(cause, err)
}

func (h *harness) trial(ctx context.Context) (err error) {
	if err := h.cfg.validate(); err != nil {
		return err
	}
	if err := os.Mkdir(h.cfg.Output, 0700); err != nil {
		return fmt.Errorf("output directory must not already exist: %w", err)
	}
	if err := os.Mkdir(filepath.Join(h.cfg.Output, "commands"), 0700); err != nil {
		return err
	}
	h.journal, err = os.OpenFile(filepath.Join(h.cfg.Output, "commands.jsonl"), os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return err
	}
	var nonce [16]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		h.journal.Close()
		return err
	}
	h.owner = hex.EncodeToString(nonce[:])
	h.name, h.volume = "royd-measure-"+h.owner, "royd-measure-"+h.owner+"-data"
	h.result = result{Format: 1, Workload: "settings-home-v1", Status: "fail", Phase: "preflight",
		Qualification: "not_requested", Comparability: "independent_review_required", Config: h.cfg,
		Started: h.now().UTC().Format(time.RFC3339Nano), Volume: h.volume, Evidence: map[string]string{},
		Unmeasured: []string{"first_visible_home_frame", "interactive_input_latency", "encoder_throughput", "host_client_cpu_time"}}
	if h.cfg.PostCheck != "" {
		h.result.Qualification = "not_run"
	}
	defer func() { err = h.finish(err) }()
	if runtime.GOOS != "linux" {
		return errors.New("the measurement harness requires a local Linux Docker engine")
	}
	if _, err := h.docker(ctx, "docker-version", "version", "--format", "{{json .}}"); err != nil {
		return err
	}
	if _, err := h.command(ctx, "host-kernel", 5*time.Second, true, "uname", "-a"); err != nil {
		return err
	}
	if _, err := h.docker(ctx, "docker-info", "info", "--format", "{{json .}}"); err != nil {
		return err
	}
	var images []struct{ ID, Architecture, Os string }
	image, err := h.docker(ctx, "image-inspect", "image", "inspect", h.cfg.Image)
	if err != nil {
		return err
	}
	if err := json.Unmarshal(image, &images); err != nil || len(images) != 1 || images[0].ID != h.cfg.Image || images[0].Architecture != "amd64" || images[0].Os != "linux" {
		return errors.New("expected one installed pinned Linux amd64 image")
	}
	h.result.Phase = "create"
	existing, err := h.docker(ctx, "volume-collision-check", "volume", "ls", "-q", "--filter", "name=^"+h.volume+"$")
	if err != nil || strings.TrimSpace(string(existing)) != "" {
		return errors.Join(err, errors.New("cannot establish a new disposable volume name"))
	}
	h.mayHaveVolume = true
	if _, err := h.docker(ctx, "volume-create", "volume", "create", "--label", ownerLabel+"="+h.owner, h.volume); err != nil {
		return err
	}
	volume, err := h.inspectVolume(ctx, "volume-created-inspect")
	if err != nil {
		return err
	}
	h.volumeCreatedAt = volume.CreatedAt
	args := []string{"create", "--pull=never", "--name", h.name, "--label", ownerLabel + "=" + h.owner,
		"--privileged", "--cgroupns=private", "--security-opt", "label=disable", "--tmpfs", "/dev/socket:rw,nosuid,nodev,noexec,mode=0755",
		"--cpus", strconv.Itoa(h.cfg.CPUs), "--memory", strconv.FormatInt(h.cfg.MemoryBytes, 10),
		"--memory-swap", strconv.FormatInt(h.cfg.MemoryBytes, 10), "--mount", "type=volume,source=" + h.volume + ",target=/data,volume-nocopy", h.cfg.Image}
	args = append(args, h.cfg.AndroidArgs...)
	h.mayHaveContainer = true
	created, err := h.docker(ctx, "container-create", args...)
	if err != nil {
		return err
	}
	h.result.Container = strings.TrimSpace(string(created))
	if !regexp.MustCompile(`^[a-f0-9]{64}$`).MatchString(h.result.Container) {
		// Recover by exact name plus ownership checks, never by an unchecked ID.
		h.result.Container = ""
		return errors.New("Docker create returned an invalid container ID")
	}
	before, err := h.inspect(ctx, "container-before-start", h.result.Container)
	if err != nil || before.State.Running || before.RestartCount != 0 || before.State.StartedAt != "0001-01-01T00:00:00Z" {
		return errors.Join(err, errors.New("measurement requires a newly created, never-started container"))
	}
	dataMounts := 0
	for _, mount := range before.Mounts {
		if mount.Destination == "/data" {
			if mount.Type != "volume" || mount.Name != h.volume {
				return errors.New("unexpected Android data mount")
			}
			dataMounts++
		}
	}
	if dataMounts != 1 || !before.HostConfig.Privileged || before.HostConfig.CgroupnsMode != "private" || before.HostConfig.NanoCpus != int64(h.cfg.CPUs)*1e9 ||
		before.HostConfig.Memory != h.cfg.MemoryBytes || before.HostConfig.MemorySwap != h.cfg.MemoryBytes {
		return errors.New("effective Docker data mount, privileges or resource limits do not match the trial")
	}
	if err := h.measure(ctx); err != nil {
		return err
	}
	if err := h.checkServer(ctx, "system-server-after-measurement"); err != nil {
		return err
	}
	if err := h.stableRunning(ctx, "container-after-measurement"); err != nil {
		return err
	}
	h.result.Phase = "post-check"
	if h.cfg.PostCheck != "" {
		h.result.Qualification = "fail"
		if _, err := h.command(ctx, "post-check", 5*time.Minute, false, h.cfg.PostCheck, h.result.Container); err != nil {
			return err
		}
		h.result.Qualification = "pass"
	}
	if err := h.checkServer(ctx, "system-server-after-postcheck"); err != nil {
		return err
	}
	return h.stableRunning(ctx, "container-after-workload")
}

func requireStart(data []byte, cold bool) (int64, error) {
	text := string(data)
	if !regexp.MustCompile(`(?m)^Status: ok\r?$`).MatchString(text) || !regexp.MustCompile(`(?m)^Complete\r?$`).MatchString(text) ||
		!regexp.MustCompile(`(?m)^Activity: [A-Za-z0-9_.]+/[A-Za-z0-9_.$]+\r?$`).MatchString(text) {
		return 0, errors.New("activity launch did not report successful completion and a concrete component")
	}
	if !cold {
		if regexp.MustCompile(`(?m)^Activity: (android/|[^\r\n]*(ResolverActivity|ChooserActivity|FallbackHome))`).MatchString(text) {
			return 0, errors.New("launch reached a resolver or fallback instead of the requested application")
		}
		return 0, nil
	}
	if !regexp.MustCompile(`(?m)^LaunchState: COLD\r?$`).MatchString(text) ||
		!regexp.MustCompile(`(?m)^Activity: com\.android\.settings/`).MatchString(text) {
		return 0, errors.New("Settings launch was not reported cold")
	}
	return number(text, `(?m)^TotalTime: ([0-9]+)\r?$`, false)
}

func number(text, pattern string, zeroOK bool) (int64, error) {
	parts := regexp.MustCompile(pattern).FindAllStringSubmatch(text, -1)
	if len(parts) != 1 {
		return 0, errors.New("required numeric metric is missing or ambiguous")
	}
	n, err := strconv.ParseInt(parts[0][1], 10, 64)
	if err != nil || n < 0 || (!zeroOK && n == 0) {
		return 0, errors.New("required numeric metric is invalid")
	}
	return n, nil
}

func effective(text, kind string) (int, int, error) {
	pattern := `(?m)^(Physical|Override) ` + kind + `: ([0-9]+)(?:x([0-9]+))?\r?$`
	parts := regexp.MustCompile(pattern).FindAllStringSubmatch(text, -1)
	values := map[string][]int{}
	for _, p := range parts {
		if _, exists := values[p[1]]; exists {
			return 0, 0, errors.New("duplicate display configuration")
		}
		x, err := strconv.Atoi(p[2])
		if err != nil || x <= 0 {
			return 0, 0, errors.New("invalid display configuration")
		}
		y := 0
		if kind == "size" {
			y, err = strconv.Atoi(p[3])
			if err != nil || y <= 0 {
				return 0, 0, errors.New("invalid display height")
			}
		} else if p[3] != "" {
			return 0, 0, errors.New("invalid density configuration")
		}
		values[p[1]] = []int{x, y}
	}
	value, ok := values["Physical"]
	if !ok {
		return 0, 0, errors.New("physical display configuration is missing")
	}
	if override, ok := values["Override"]; ok {
		value = override
	}
	return value[0], value[1], nil
}

func (h *harness) measure(ctx context.Context) error {
	h.result.Phase = "observed-home"
	started := h.now() // Includes the start CLI call, not image/volume creation.
	bootCtx, cancel := context.WithTimeout(ctx, h.cfg.BootTimeout)
	defer cancel()
	if _, err := h.docker(bootCtx, "container-start", "start", h.result.Container); err != nil {
		return err
	}
	state, err := h.inspect(bootCtx, "container-started", h.result.Container)
	if err != nil || !state.State.Running || state.State.OOMKilled || state.RestartCount != 0 || state.State.StartedAt == "" || state.State.StartedAt == "0001-01-01T00:00:00Z" {
		return errors.Join(err, errors.New("container did not enter a valid fresh running state"))
	}
	h.result.DockerStarted = state.State.StartedAt
	// Identical fixed delay for every runtime. No image-specific log/property
	// gate, and no early exec while Android may still be delegating cgroups.
	if err := h.sleep(bootCtx, h.cfg.StartupDelay); err != nil {
		return err
	}
	for {
		if h.now().Sub(started) >= h.cfg.BootTimeout {
			return errors.New("observed boot deadline exhausted")
		}
		state, err := h.inspect(bootCtx, "boot-state", h.result.Container)
		if err != nil || !state.State.Running || state.State.OOMKilled || state.RestartCount != 0 || state.State.StartedAt != h.result.DockerStarted {
			return errors.Join(err, errors.New("container unavailable during boot"))
		}
		boot, err := h.android(bootCtx, "boot-property", "getprop", "sys.boot_completed")
		if err == nil && strings.TrimSpace(string(boot)) == "1" {
			break
		}
		if err := h.sleep(bootCtx, time.Second); err != nil {
			return err
		}
	}
	if err := h.wake(bootCtx); err != nil {
		return err
	}
	home, err := h.android(bootCtx, "observed-home", "am", "start", "-W", "--user", "0", "-a", "android.intent.action.MAIN", "-c", "android.intent.category.HOME")
	if err != nil {
		return err
	}
	if _, err := requireStart(home, false); err != nil {
		return err
	}
	duration := milliseconds(h.now().Sub(started))
	h.result.Metrics.ObservedHomeMS = &duration
	h.result.Phase = "provenance"
	if err := h.checkServer(ctx, "system-server-before"); err != nil {
		return err
	}
	for _, item := range []struct {
		name string
		args []string
	}{
		{"android-properties", []string{"getprop"}}, {"settings-version", []string{"dumpsys", "package", "com.android.settings"}},
		{"surfaceflinger", []string{"dumpsys", "SurfaceFlinger"}}, {"display", []string{"dumpsys", "display"}},
	} {
		if _, err := h.android(ctx, item.name, item.args...); err != nil {
			return err
		}
	}
	sdk, err := h.android(ctx, "sdk", "getprop", "ro.build.version.sdk")
	if err != nil || strings.TrimSpace(string(sdk)) != "35" {
		return errors.Join(err, errors.New("this workload is scoped to Android 15"))
	}
	size, err := h.android(ctx, "wm-size", "wm", "size")
	if err != nil {
		return err
	}
	w, height, err := effective(string(size), "size")
	if err != nil || w != h.cfg.Width || height != h.cfg.Height {
		return errors.Join(err, errors.New("effective display size does not match the workload"))
	}
	density, err := h.android(ctx, "wm-density", "wm", "density")
	if err != nil {
		return err
	}
	dpi, _, err := effective(string(density), "density")
	if err != nil || dpi != h.cfg.DPI {
		return errors.Join(err, errors.New("effective display density does not match the workload"))
	}
	h.result.Phase = "settle"
	if err := h.sleep(ctx, h.cfg.Settle); err != nil {
		return err
	}
	settled, err := h.counter(ctx, "settled-memory", "/sys/fs/cgroup/memory.current", `\A([0-9]+)\s*\z`)
	if err != nil || settled == 0 {
		return errors.Join(err, errors.New("settled memory is unavailable or zero"))
	}
	h.result.Metrics.SettledBytes = &settled
	cpuBefore, err := h.counter(ctx, "cpu-before", "/sys/fs/cgroup/cpu.stat", `(?m)^usage_usec ([0-9]+)$`)
	if err != nil {
		return err
	}
	h.result.Phase = "cold-launches"
	for i := 0; i < h.cfg.Launches; i++ {
		if _, err := h.android(ctx, "settings-force-stop", "am", "force-stop", "--user", "0", "com.android.settings"); err != nil {
			return err
		}
		if _, err := h.android(ctx, "settings-stopped", "sh", "-c", "if pidof com.android.settings >/dev/null; then exit 1; fi"); err != nil {
			return errors.New("old Settings process remains after force-stop")
		}
		if err := h.wake(ctx); err != nil {
			return err
		}
		started := h.now()
		output, err := h.android(ctx, "settings-cold-launch", "am", "start", "-W", "--user", "0", "-n", "com.android.settings/.Settings")
		if err != nil {
			return err
		}
		wall := milliseconds(h.now().Sub(started))
		total, err := requireStart(output, true)
		if err != nil {
			return err
		}
		h.result.Metrics.ColdLaunches = append(h.result.Metrics.ColdLaunches, launch{total, wall})
	}
	h.result.Phase = "frame-workload"
	if err := h.wake(ctx); err != nil {
		return err
	}
	if _, err := h.android(ctx, "gfx-reset", "dumpsys", "gfxinfo", "com.android.settings", "reset"); err != nil {
		return err
	}
	x, top, bottom := strconv.Itoa(w/2), strconv.Itoa(height/4), strconv.Itoa(height*3/4)
	for i := 0; i < 4; i++ {
		from, to := bottom, top
		if i%2 == 1 {
			from, to = to, from
		}
		if _, err := h.android(ctx, "settings-scroll", "input", "swipe", x, from, x, to, "400"); err != nil {
			return err
		}
	}
	if err := h.sleep(ctx, time.Second); err != nil {
		return err
	}
	gfx, err := h.android(ctx, "gfx-result", "dumpsys", "gfxinfo", "com.android.settings")
	if err != nil {
		return err
	}
	frames, err := number(string(gfx), `(?m)^Total frames rendered: ([0-9]+)\r?$`, false)
	if err != nil {
		return err
	}
	janky, err := number(string(gfx), `(?m)^Janky frames: ([0-9]+) \([0-9.]+%\)\r?$`, true)
	if err != nil || janky > frames {
		return errors.Join(err, errors.New("invalid janky frame count"))
	}
	p50, err := number(string(gfx), `(?m)^50th percentile: ([0-9]+)ms\r?$`, true)
	if err != nil {
		return err
	}
	p90, err := number(string(gfx), `(?m)^90th percentile: ([0-9]+)ms\r?$`, true)
	if err != nil || p90 < p50 {
		return errors.Join(err, errors.New("invalid frame percentile ordering"))
	}
	h.result.Metrics.Frames, h.result.Metrics.JankyFrames = &frames, &janky
	h.result.Metrics.FrameP50MS, h.result.Metrics.FrameP90MS = &p50, &p90
	h.result.Phase = "settings-home-cycles"
	for i := 0; i < h.cfg.Cycles; i++ {
		output, err := h.android(ctx, "cycle-settings", "am", "start", "-W", "--user", "0", "-n", "com.android.settings/.Settings")
		if err != nil {
			return err
		}
		if _, err := requireStart(output, false); err != nil {
			return err
		}
		if _, err := h.android(ctx, "cycle-scroll", "input", "swipe", x, bottom, x, top, "400"); err != nil {
			return err
		}
		if _, err := h.android(ctx, "cycle-home", "input", "keyevent", "HOME"); err != nil {
			return err
		}
	}
	cpuAfter, err := h.counter(ctx, "cpu-after", "/sys/fs/cgroup/cpu.stat", `(?m)^usage_usec ([0-9]+)$`)
	if err != nil || cpuAfter <= cpuBefore {
		return errors.Join(err, errors.New("container CPU counter did not advance"))
	}
	cpu := cpuAfter - cpuBefore
	h.result.Metrics.CPUUsec = &cpu
	peak, err := h.counter(ctx, "lifetime-memory-peak", "/sys/fs/cgroup/memory.peak", `\A([0-9]+)\s*\z`)
	if err != nil || peak < settled {
		return errors.Join(err, errors.New("invalid lifetime memory peak"))
	}
	h.result.Metrics.PeakBytes = &peak
	return nil
}

func (h *harness) counter(ctx context.Context, label, path, pattern string) (int64, error) {
	output, err := h.android(ctx, label, "cat", path)
	if err != nil {
		return 0, err
	}
	return number(string(output), pattern, true)
}

func (h *harness) wake(ctx context.Context) error {
	for _, command := range [][]string{{"cmd", "power", "wakeup"}, {"input", "keyevent", "82"}} {
		if _, err := h.android(ctx, "wake-unlock", command...); err != nil {
			return err
		}
	}
	return nil
}

func main() {
	c := defaults()
	flag.StringVar(&c.Image, "image", "", "explicit installed sha256 image ID (never pulled)")
	flag.StringVar(&c.Output, "output", "", "new evidence directory; parent must exist")
	flag.StringVar(&c.Socket, "socket", c.Socket, "absolute local Docker Unix socket")
	flag.StringVar(&c.PostCheck, "post-check", "", "optional trusted host executable, called with container ID after measurement")
	flag.BoolVar(&c.Privileged, "privileged", false, "acknowledge privileged operation and prior independent image safety review")
	flag.IntVar(&c.CPUs, "cpus", c.CPUs, "identical CPU quota for every trial")
	flag.Int64Var(&c.MemoryBytes, "memory-bytes", c.MemoryBytes, "identical memory and memory-plus-swap limit")
	flag.IntVar(&c.Width, "width", c.Width, "expected effective display width")
	flag.IntVar(&c.Height, "height", c.Height, "expected effective display height")
	flag.IntVar(&c.DPI, "dpi", c.DPI, "expected effective display density")
	flag.IntVar(&c.Launches, "launches", c.Launches, "cold Settings launch repetitions")
	flag.IntVar(&c.Cycles, "cycles", c.Cycles, "Settings/scroll/Home cycles")
	flag.DurationVar(&c.BootTimeout, "boot-timeout", c.BootTimeout, "overall observed-Home deadline")
	flag.DurationVar(&c.StartupDelay, "startup-delay", c.StartupDelay, "common passive interval before any Android exec, counted in startup time")
	flag.DurationVar(&c.Settle, "settle", c.Settle, "settle interval before workload counters")
	flag.Parse()
	c.AndroidArgs = flag.Args()
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	h := harness{cfg: c, run: execute(c.Socket), now: time.Now, sleep: sleepContext}
	if err := h.trial(ctx); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
	fmt.Println("Measurement trial passed; independent comparability review is still required:", c.Output)
}

func (h *harness) checkServer(ctx context.Context, label string) error {
	output, err := h.android(ctx, label, "pidof", "system_server")
	if err != nil {
		return err
	}
	pid := strings.TrimSpace(string(output))
	if !regexp.MustCompile(`^[1-9][0-9]*$`).MatchString(pid) || (h.result.SystemServer != "" && pid != h.result.SystemServer) {
		return errors.New("SystemServer identity is missing, ambiguous or changed during the trial")
	}
	h.result.SystemServer = pid
	return nil
}

func (h *harness) stableRunning(ctx context.Context, label string) error {
	state, err := h.inspect(ctx, label, h.result.Container)
	if err != nil || !state.State.Running || state.State.OOMKilled || state.RestartCount != 0 || state.State.StartedAt != h.result.DockerStarted {
		return errors.Join(err, errors.New("container stopped, restarted, changed start time or was OOM-killed during the trial"))
	}
	return nil
}
