package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const imageID = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
const containerID = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
const goodLaunch = "Status: ok\nLaunchState: COLD\nActivity: com.android.settings/.Settings\nTotalTime: 50\nComplete\n"
const goodHome = "Status: ok\nLaunchState: HOT\nActivity: com.android.launcher3/.Launcher\nComplete\n"
const goodGfx = "Total frames rendered: 40\nJanky frames: 2 (5.00%)\n50th percentile: 8ms\n90th percentile: 16ms\n"

type fake struct {
	h                                   *harness
	clock                               time.Time
	mode                                string
	volume, container, started, cpuRead bool
	removedVolume, removedContainer     bool
	postRan                             bool
	serverReads                         int
	firstExecDelay                      time.Duration
	startTime                           time.Time
	startCalls                          int
	commands                            []string
}

func fixture(t *testing.T, mode string) (*harness, *fake) {
	t.Helper()
	c := defaults()
	c.Image, c.Output, c.Privileged = imageID, filepath.Join(t.TempDir(), "evidence"), true
	c.PostCheck = "/trusted/post-check"
	f := &fake{clock: time.Unix(1000, 0), mode: mode}
	h := &harness{cfg: c, now: func() time.Time { return f.clock }, sleep: func(ctx context.Context, d time.Duration) error {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		f.clock = f.clock.Add(d)
		return nil
	}}
	f.h, h.run = h, f.run
	return h, f
}

func (f *fake) run(ctx context.Context, tool string, args []string, out, stderr io.Writer) error {
	if ctx.Err() != nil {
		return ctx.Err()
	}
	f.clock = f.clock.Add(10 * time.Millisecond)
	f.commands = append(f.commands, tool+" "+strings.Join(args, " "))
	if tool == "uname" {
		fmt.Fprintln(out, "Linux test")
		return nil
	}
	if tool == "/trusted/post-check" {
		f.postRan = true
		f.clock = f.clock.Add(60 * time.Second)
		if f.mode == "post_failure" {
			return errors.New("post-check failed")
		}
		return nil
	}
	if tool != "docker" || len(args) < 3 || args[0] != "--host" || args[1] != "unix:///var/run/docker.sock" {
		return errors.New("unexpected command")
	}
	args = args[2:]
	text := strings.Join(args, " ")
	write := func(value any) error { return json.NewEncoder(out).Encode(value) }
	switch args[0] {
	case "version", "info":
		fmt.Fprintln(out, `{}`)
	case "image":
		if f.mode == "missing_image" {
			return errors.New("no image")
		}
		arch := "amd64"
		if f.mode == "wrong_arch" {
			arch = "arm64"
		}
		return write([]map[string]any{{"Id": imageID, "Architecture": arch, "Os": "linux"}})
	case "volume":
		switch args[1] {
		case "ls":
			if f.mode == "volume_collision" {
				fmt.Fprintln(out, f.h.volume)
			}
		case "create":
			f.volume = true
			if f.mode == "volume_partial" {
				return errors.New("lost create response")
			}
			fmt.Fprintln(out, f.h.volume)
		case "inspect":
			if !f.volume {
				return errors.New("no volume")
			}
			owner := f.h.owner
			if f.mode == "foreign_volume" {
				owner = "someone-else"
			}
			if f.mode == "replaced_volume" && f.started {
				owner = "someone-else"
			}
			return write([]volumeInfo{{Name: f.h.volume, CreatedAt: "test-created", Labels: map[string]string{ownerLabel: owner}}})
		case "rm":
			f.removedVolume = true
			f.volume = false
		default:
			return errors.New("unexpected volume operation")
		}
	case "create":
		for _, required := range []string{"--pull=never", "--cgroupns=private", "--memory 4294967296", "--memory-swap 4294967296", "--cpus 4", "volume-nocopy"} {
			if !strings.Contains(text, required) {
				return fmt.Errorf("missing safety setting %s", required)
			}
		}
		f.container = true
		if f.mode == "container_partial" {
			return errors.New("lost container create response")
		}
		fmt.Fprintln(out, containerID)
	case "inspect":
		if !f.container {
			return errors.New("no container")
		}
		x := containerInfo{ID: containerID, Image: imageID}
		x.Config.Labels = map[string]string{ownerLabel: f.h.owner}
		x.HostConfig.NanoCpus = 4e9
		x.HostConfig.Memory = 4 << 30
		x.HostConfig.MemorySwap = 4 << 30
		x.HostConfig.Privileged = true
		x.HostConfig.CgroupnsMode = "private"
		x.Mounts = append(x.Mounts, struct{ Type, Name, Destination string }{"volume", f.h.volume, "/data"})
		x.State.Running = f.started
		x.State.StartedAt = "0001-01-01T00:00:00Z"
		if f.started {
			x.State.StartedAt = "started"
		}
		if f.mode == "manual_restart" && f.cpuRead {
			x.State.StartedAt = "restarted-manually"
		}
		if f.mode == "foreign_container" {
			x.Config.Labels[ownerLabel] = "foreign"
		}
		if f.mode == "wrong_limits" {
			x.HostConfig.Memory = 1
		}
		if f.mode == "host_cgroups" {
			x.HostConfig.CgroupnsMode = "host"
		}
		if f.mode == "wrong_data" {
			x.Mounts[0].Name = "user-data"
		}
		if f.mode == "restarted" && f.started {
			x.RestartCount = 1
		}
		if f.mode == "oom" && f.started {
			x.State.OOMKilled = true
		}
		return write([]containerInfo{x})
	case "start":
		f.started = true
		f.startTime = f.clock
		f.startCalls++
		if f.mode == "start_failure" {
			return errors.New("start failed")
		}
		fmt.Fprintln(out, containerID)
	case "logs":
		fmt.Fprintln(out, "full logs, including warnings")
		if f.mode == "log_failure" {
			return errors.New("capture failed")
		}
	case "rm":
		if text != "rm -f -v "+containerID {
			return errors.New("cleanup must use exact ID and remove its anonymous volumes")
		}
		if f.mode == "cleanup_failure" {
			return errors.New("cleanup failed")
		}
		f.removedContainer = true
		f.container = false
	case "exec":
		if len(args) < 5 || args[1] != containerID || args[2] != "timeout" || args[3] != "25" {
			return errors.New("unbounded or incorrect exec")
		}
		if f.firstExecDelay == 0 {
			f.firstExecDelay = f.clock.Sub(f.startTime)
		}
		command := strings.Join(args[4:], " ")
		switch command {
		case "pidof system_server":
			f.serverReads++
			if f.mode == "server_changed" && f.serverReads > 1 || f.mode == "server_changed_post" && f.postRan {
				fmt.Fprintln(out, "778")
			} else {
				fmt.Fprintln(out, "777")
			}
		case "getprop sys.boot_completed":
			if f.mode == "boot_timeout" {
				fmt.Fprintln(out, "0")
			} else {
				fmt.Fprintln(out, "1")
			}
		case "getprop ro.build.version.sdk":
			if f.mode == "wrong_sdk" {
				fmt.Fprintln(out, "34")
			} else {
				fmt.Fprintln(out, "35")
			}
		case "cmd power wakeup", "input keyevent 82", "am force-stop --user 0 com.android.settings", "dumpsys gfxinfo com.android.settings reset", "input keyevent HOME":
		case "sh -c if pidof com.android.settings >/dev/null; then exit 1; fi":
			if f.mode == "old_process" {
				return errors.New("old process remains")
			}
		case "getprop", "dumpsys package com.android.settings", "dumpsys SurfaceFlinger", "dumpsys display":
			fmt.Fprintln(out, "raw provenance")
		case "wm size":
			if f.mode == "wrong_size" {
				fmt.Fprintln(out, "Physical size: 1080x1920")
			} else {
				fmt.Fprintln(out, "Physical size: 540x960")
			}
		case "wm density":
			if f.mode == "wrong_density" {
				fmt.Fprintln(out, "Physical density: 213")
			} else {
				fmt.Fprintln(out, "Physical density: 240")
			}
		case "cat /sys/fs/cgroup/memory.current":
			if f.mode == "zero_memory" {
				fmt.Fprintln(out, "0")
			} else {
				fmt.Fprintln(out, "1000000")
			}
		case "cat /sys/fs/cgroup/memory.peak":
			if f.mode == "bad_peak" {
				fmt.Fprintln(out, "1")
			} else {
				fmt.Fprintln(out, "2000000")
			}
		case "cat /sys/fs/cgroup/cpu.stat":
			n := 100
			if f.cpuRead && f.mode != "cpu_stalled" {
				n = 200
			}
			f.cpuRead = true
			fmt.Fprintf(out, "usage_usec %d\n", n)
		case "dumpsys gfxinfo com.android.settings":
			if f.mode == "bad_gfx" {
				fmt.Fprintln(out, "Total frames rendered: 0")
			} else {
				fmt.Fprint(out, goodGfx)
			}
		case "am start -W --user 0 -a android.intent.action.MAIN -c android.intent.category.HOME":
			if f.mode == "fallback_home" {
				fmt.Fprint(out, strings.ReplaceAll(goodHome, "com.android.launcher3/.Launcher", "com.android.settings/.FallbackHome"))
			} else {
				fmt.Fprint(out, goodHome)
			}
		case "am start -W --user 0 -n com.android.settings/.Settings":
			if f.mode == "warm_launch" {
				fmt.Fprint(out, strings.ReplaceAll(goodLaunch, "COLD", "HOT"))
			} else {
				fmt.Fprint(out, goodLaunch)
			}
		default:
			if !strings.HasPrefix(command, "input swipe ") {
				return fmt.Errorf("unexpected Android command %s", command)
			}
		}
	default:
		return errors.New("unexpected Docker command")
	}
	return nil
}

func readResult(t *testing.T, h *harness) result {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(h.cfg.Output, "result.json"))
	if err != nil {
		t.Fatal(err)
	}
	var r result
	if err := json.Unmarshal(data, &r); err != nil {
		t.Fatal(err)
	}
	return r
}

func TestTrial(t *testing.T) {
	for _, mode := range []string{"good", "missing_image", "wrong_arch", "volume_collision", "volume_partial", "foreign_volume", "container_partial", "foreign_container", "wrong_limits", "host_cgroups", "wrong_data", "start_failure", "restarted", "oom", "boot_timeout", "wrong_sdk", "wrong_size", "wrong_density", "zero_memory", "old_process", "warm_launch", "fallback_home", "bad_gfx", "cpu_stalled", "bad_peak", "post_failure", "log_failure", "cleanup_failure", "replaced_volume", "server_changed", "server_changed_post"} {
		t.Run(mode, func(t *testing.T) {
			h, f := fixture(t, mode)
			err := h.trial(context.Background())
			r := readResult(t, h)
			if mode == "good" {
				if err != nil || r.Status != "pass" || r.Qualification != "pass" || r.Phase != "complete" {
					t.Fatalf("%+v %v", r, err)
				}
				if !f.removedContainer || !f.removedVolume || !f.postRan || f.startCalls != 1 {
					t.Fatal("incomplete lifecycle")
				}
				if f.firstExecDelay < h.cfg.StartupDelay || *r.Metrics.ObservedHomeMS >= 60000 {
					t.Fatal("startup gate or post-check timer contamination")
				}
				if len(r.Metrics.ColdLaunches) != 5 || *r.Metrics.CPUUsec != 100 || *r.Metrics.Frames != 40 || r.Comparability != "independent_review_required" {
					t.Fatalf("wrong metrics: %+v", r)
				}
			} else if err == nil || r.Status != "fail" || r.Error == "" {
				t.Fatalf("failure accepted: %+v %v", r, err)
			}
			if mode == "foreign_volume" || mode == "volume_collision" || mode == "replaced_volume" {
				if f.removedVolume {
					t.Fatal("unrelated volume removed")
				}
			}
			if mode == "foreign_container" && f.removedContainer {
				t.Fatal("unrelated container removed")
			}
			if mode == "container_partial" && (!f.removedContainer || !f.removedVolume) {
				t.Fatal("partial creation not recovered")
			}
			if mode == "volume_partial" && !f.removedVolume {
				t.Fatal("partial volume not recovered")
			}
			if mode == "log_failure" && !f.removedContainer {
				t.Fatal("log failure prevented owned cleanup")
			}
			journal, err := os.ReadFile(filepath.Join(h.cfg.Output, "commands.jsonl"))
			if err != nil || len(journal) == 0 {
				t.Fatal("journal missing")
			}
			if f.started {
				if _, ok := r.Evidence["container-log"]; !ok {
					t.Fatal("full logs not retained")
				}
			}
		})
	}
}

func TestOutputNeverOverwritten(t *testing.T) {
	h, f := fixture(t, "good")
	if err := os.Mkdir(h.cfg.Output, 0700); err != nil {
		t.Fatal(err)
	}
	p := filepath.Join(h.cfg.Output, "keep")
	if err := os.WriteFile(p, []byte("user evidence"), 0600); err != nil {
		t.Fatal(err)
	}
	if h.trial(context.Background()) == nil || len(f.commands) != 0 {
		t.Fatal("existing output adopted")
	}
	data, _ := os.ReadFile(p)
	if string(data) != "user evidence" {
		t.Fatal("evidence changed")
	}
}

func TestInvalidConfig(t *testing.T) {
	for _, mutate := range []func(*config){
		func(c *config) { c.Image = "image:latest" }, func(c *config) { c.Image = "sha256:short" },
		func(c *config) { c.Privileged = false }, func(c *config) { c.Output = "" }, func(c *config) { c.Socket = "tcp://remote" },
		func(c *config) { c.MemoryBytes = 1 }, func(c *config) { c.CPUs = 0 }, func(c *config) { c.Width = 0 },
		func(c *config) { c.Launches = 0 }, func(c *config) { c.Cycles = 0 }, func(c *config) { c.StartupDelay = c.BootTimeout },
		func(c *config) { c.Settle = -1 }, func(c *config) { c.PostCheck = "relative" },
	} {
		h, f := fixture(t, "good")
		mutate(&h.cfg)
		if h.trial(context.Background()) == nil || len(f.commands) != 0 {
			t.Fatal("invalid configuration reached Docker")
		}
	}
}

func TestParsers(t *testing.T) {
	for _, text := range []string{"", strings.ReplaceAll(goodLaunch, "Status: ok", "Status: timeout"), strings.ReplaceAll(goodLaunch, "COLD", "UNKNOWN"), strings.ReplaceAll(goodLaunch, "50", "-1"), strings.ReplaceAll(goodLaunch, "TotalTime: 50", "TotalTime: 0"), goodLaunch + "TotalTime: 5\n"} {
		if _, err := requireStart([]byte(text), true); err == nil {
			t.Fatalf("invalid launch accepted: %q", text)
		}
	}
	if n, err := requireStart([]byte(strings.ReplaceAll(goodLaunch, "\n", "\r\n")), true); err != nil || n != 50 {
		t.Fatal(n, err)
	}
	w, h, err := effective("Physical size: 1080x1920\nOverride size: 540x960\n", "size")
	if err != nil || w != 540 || h != 960 {
		t.Fatal(w, h, err)
	}
	for _, text := range []string{"", "Override size: 540x960\n", "Physical size: 0x960\n", "Physical size: 540x960\nPhysical size: 540x960\n"} {
		if _, _, err := effective(text, "size"); err == nil {
			t.Fatal("bad display accepted")
		}
	}
	for _, text := range []string{"", "-1", "9223372036854775808", "123 garbage"} {
		if _, err := number(text, `\A([0-9]+)\s*\z`, true); err == nil {
			t.Fatal("invalid counter accepted")
		}
	}
}

func TestEnvironment(t *testing.T) {
	t.Setenv("DOCKER_HOST", "tcp://remote")
	t.Setenv("DOCKER_CONTEXT", "remote-context")
	joined := strings.Join(cleanEnvironment("/var/run/docker.sock"), "\n")
	if strings.Contains(joined, "remote") || !strings.Contains(joined, "DOCKER_HOST=unix:///var/run/docker.sock") {
		t.Fatal("Docker endpoint override leaked")
	}
}

func TestCancellationRetainsFailure(t *testing.T) {
	h, f := fixture(t, "good")
	ctx, cancel := context.WithCancel(context.Background())
	base := h.run
	h.run = func(c context.Context, tool string, args []string, out, stderr io.Writer) error {
		err := base(c, tool, args, out, stderr)
		if tool == "docker" && len(args) > 2 && args[2] == "start" {
			cancel()
		}
		return err
	}
	if h.trial(ctx) == nil || readResult(t, h).Status != "fail" || !f.removedContainer || !f.removedVolume {
		t.Fatal("interruption lost evidence or cleanup")
	}
}

func TestExecuteTimeoutAndFailureOutput(t *testing.T) {
	var out, stderr strings.Builder
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	started := time.Now()
	if execute("/var/run/docker.sock")(ctx, "sh", []string{"-c", "sleep 10 & wait"}, &out, &stderr) == nil || time.Since(started) > 2*time.Second {
		t.Fatal("command descendants were not bounded")
	}
	out.Reset()
	stderr.Reset()
	if execute("/var/run/docker.sock")(context.Background(), "sh", []string{"-c", "printf retained; printf failure >&2; exit 3"}, &out, &stderr) == nil || out.String() != "retained" || stderr.String() != "failure" {
		t.Fatal("failed command output was not retained")
	}
}

func TestNoPostCheckIsNotQualification(t *testing.T) {
	h, f := fixture(t, "good")
	h.cfg.PostCheck = ""
	if err := h.trial(context.Background()); err != nil {
		t.Fatal(err)
	}
	if readResult(t, h).Qualification != "not_requested" || f.postRan {
		t.Fatal("missing check called qualified")
	}
	h, _ = fixture(t, "bad_gfx")
	if h.trial(context.Background()) == nil || readResult(t, h).Qualification != "not_run" {
		t.Fatal("unreached check misclassified")
	}
}

func TestManualRestartWithZeroRestartCount(t *testing.T) {
	h, f := fixture(t, "manual_restart")
	if h.trial(context.Background()) == nil || readResult(t, h).Status != "fail" || !f.removedContainer || !f.removedVolume {
		t.Fatal("manual restart with zero automatic restart count was accepted")
	}
}
