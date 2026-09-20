package main

import (
	"reflect"
	"testing"
)

type fakeRunner struct {
	calls   [][]string
	outputs [][]byte
}

func (r *fakeRunner) Run(args ...string) error {
	copyArgs := append([]string(nil), args...)
	r.calls = append(r.calls, copyArgs)
	return nil
}

func (r *fakeRunner) Output(args ...string) ([]byte, error) {
	copyArgs := append([]string(nil), args...)
	r.calls = append(r.calls, copyArgs)
	if len(r.outputs) == 0 {
		return nil, nil
	}
	out := r.outputs[0]
	r.outputs = r.outputs[1:]
	return out, nil
}

type fakeADBRunner struct {
	calls [][]string
}

func (r *fakeADBRunner) Run(args ...string) error {
	copyArgs := append([]string(nil), args...)
	r.calls = append(r.calls, copyArgs)
	return nil
}

func assertSingleCall(t *testing.T, runner *fakeRunner, want []string) {
	t.Helper()
	if len(runner.calls) != 1 {
		t.Fatalf("expected one docker call, got %d", len(runner.calls))
	}
	if !reflect.DeepEqual(runner.calls[0], want) {
		t.Fatalf("unexpected docker args:\n got: %#v\nwant: %#v", runner.calls[0], want)
	}
}

func TestRunContainerDefaults(t *testing.T) {
	runner := &fakeRunner{}
	if err := execute(runner, []string{"run"}); err != nil {
		t.Fatal(err)
	}
	assertSingleCall(t, runner, []string{
		"run", "-d", "--privileged", "--name", "royd",
		"--label", "org.royd.instance=true",
		"-v", "royd-data:/data",
		"-p", "127.0.0.1:5555:5555",
		"royd:dev",
		"royd.width=540",
		"royd.height=960",
		"royd.dpi=240",
		"royd.fps=30",
	})
}

func TestRunContainerOverrides(t *testing.T) {
	runner := &fakeRunner{}
	args := []string{"run", "--name", "test", "--image", "example/royd:test", "--volume", "test-data", "--port", "127.0.0.1:5560:5555", "--memory", "768m", "--width", "360", "--height", "640", "--dpi", "160", "--fps", "24"}
	if err := execute(runner, args); err != nil {
		t.Fatal(err)
	}
	assertSingleCall(t, runner, []string{
		"run", "-d", "--privileged", "--name", "test",
		"--label", "org.royd.instance=true",
		"-v", "test-data:/data",
		"-p", "127.0.0.1:5560:5555",
		"--memory", "768m", "--memory-swap", "768m",
		"example/royd:test",
		"royd.width=360",
		"royd.height=640",
		"royd.dpi=160",
		"royd.fps=24",
	})
}

func TestRunContainerExperimentalSecurity(t *testing.T) {
	runner := &fakeRunner{}
	if err := execute(runner, []string{"run", "--security", "experimental"}); err != nil {
		t.Fatal(err)
	}
	assertSingleCall(t, runner, []string{
		"run", "-d",
		"--cap-add=SYS_ADMIN",
		"--cap-add=NET_ADMIN",
		"--cap-add=SYS_NICE",
		"--cap-add=SYS_RESOURCE",
		"--cap-add=SYS_PTRACE",
		"--name", "royd",
		"--label", "org.royd.instance=true",
		"-v", "royd-data:/data",
		"-p", "127.0.0.1:5555:5555",
		"royd:dev",
		"royd.width=540",
		"royd.height=960",
		"royd.dpi=240",
		"royd.fps=30",
	})
}

func TestRunContainerHostGPU(t *testing.T) {
	runner := &fakeRunner{}
	if err := execute(runner, []string{"run", "--graphics", "host-gpu-generic"}); err != nil {
		t.Fatal(err)
	}
	assertSingleCall(t, runner, []string{
		"run", "-d", "--privileged", "--device=/dev/dri:/dev/dri",
		"--name", "royd",
		"--label", "org.royd.instance=true",
		"-v", "royd-data:/data",
		"-p", "127.0.0.1:5555:5555",
		"royd:dev-host-gpu-generic",
		"royd.width=540",
		"royd.height=960",
		"royd.dpi=240",
		"royd.fps=30",
	})
}

func TestRunContainerRejectsUnknownGraphicsBackend(t *testing.T) {
	runner := &fakeRunner{}
	if err := execute(runner, []string{"run", "--graphics", "unknown"}); err == nil {
		t.Fatal("expected invalid graphics backend error")
	}
	if len(runner.calls) != 0 {
		t.Fatalf("expected no docker calls, got %d", len(runner.calls))
	}
}

func TestRunContainerRejectsUnknownSecurityMode(t *testing.T) {
	runner := &fakeRunner{}
	if err := execute(runner, []string{"run", "--security", "unknown"}); err == nil {
		t.Fatal("expected invalid security mode error")
	}
	if len(runner.calls) != 0 {
		t.Fatalf("expected no docker calls, got %d", len(runner.calls))
	}
}

func TestRunContainerRejectsInvalidDisplay(t *testing.T) {
	runner := &fakeRunner{}
	if err := execute(runner, []string{"run", "--width", "0"}); err == nil {
		t.Fatal("expected invalid display error")
	}
	if len(runner.calls) != 0 {
		t.Fatalf("expected no docker calls, got %d", len(runner.calls))
	}
}

func TestPSIncludesStoppedContainers(t *testing.T) {
	runner := &fakeRunner{}
	if err := execute(runner, []string{"ps"}); err != nil {
		t.Fatal(err)
	}
	assertSingleCall(t, runner, []string{"ps", "-a", "--filter", "label=org.royd.instance=true"})
}

func TestLogs(t *testing.T) {
	runner := &fakeRunner{}
	if err := execute(runner, []string{"logs", "--f=false", "royd-test"}); err != nil {
		t.Fatal(err)
	}
	assertSingleCall(t, runner, []string{"logs", "royd-test"})
}

func TestShell(t *testing.T) {
	runner := &fakeRunner{}
	if err := execute(runner, []string{"shell", "royd-test"}); err != nil {
		t.Fatal(err)
	}
	assertSingleCall(t, runner, []string{"exec", "-it", "royd-test", "/system/bin/sh"})
}

func TestStop(t *testing.T) {
	runner := &fakeRunner{}
	if err := execute(runner, []string{"stop", "royd-test"}); err != nil {
		t.Fatal(err)
	}
	assertSingleCall(t, runner, []string{"stop", "royd-test"})
}

func TestRemoveForce(t *testing.T) {
	runner := &fakeRunner{}
	if err := execute(runner, []string{"rm", "-f", "royd-test"}); err != nil {
		t.Fatal(err)
	}
	assertSingleCall(t, runner, []string{"rm", "-f", "royd-test"})
}

func TestStatus(t *testing.T) {
	runner := &fakeRunner{outputs: [][]byte{[]byte("running\n"), []byte("healthy\n"), []byte("127.0.0.1:5555\n")}}
	if err := execute(runner, []string{"status", "royd-test"}); err != nil {
		t.Fatal(err)
	}
	want := [][]string{
		{"inspect", "--format", "{{.State.Status}}", "royd-test"},
		{"inspect", "--format", "{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}", "royd-test"},
		{"port", "royd-test", "5555/tcp"},
	}
	if !reflect.DeepEqual(runner.calls, want) {
		t.Fatalf("unexpected docker calls:\n got: %#v\nwant: %#v", runner.calls, want)
	}
}

func TestADBDefaultsToShell(t *testing.T) {
	dockerRunner := &fakeRunner{}
	adbRunner := &fakeADBRunner{}
	if err := executeWithADB(dockerRunner, adbRunner, []string{"adb"}); err != nil {
		t.Fatal(err)
	}
	want := [][]string{{"connect", "127.0.0.1:5555"}, {"-s", "127.0.0.1:5555", "shell"}}
	if !reflect.DeepEqual(adbRunner.calls, want) {
		t.Fatalf("unexpected adb calls:\n got: %#v\nwant: %#v", adbRunner.calls, want)
	}
}

func TestADBPassesArguments(t *testing.T) {
	dockerRunner := &fakeRunner{}
	adbRunner := &fakeADBRunner{}
	if err := executeWithADB(dockerRunner, adbRunner, []string{"adb", "--serial", "127.0.0.1:5560", "logcat", "-d"}); err != nil {
		t.Fatal(err)
	}
	want := [][]string{{"connect", "127.0.0.1:5560"}, {"-s", "127.0.0.1:5560", "logcat", "-d"}}
	if !reflect.DeepEqual(adbRunner.calls, want) {
		t.Fatalf("unexpected adb calls:\n got: %#v\nwant: %#v", adbRunner.calls, want)
	}
}
