package main

import (
	"reflect"
	"testing"
)

type fakeRunner struct {
	calls [][]string
}

func (r *fakeRunner) Run(args ...string) error {
	copyArgs := append([]string(nil), args...)
	r.calls = append(r.calls, copyArgs)
	return nil
}

func (r *fakeRunner) Output(args ...string) ([]byte, error) {
	copyArgs := append([]string(nil), args...)
	r.calls = append(r.calls, copyArgs)
	return nil, nil
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
	})
}

func TestRunContainerOverrides(t *testing.T) {
	runner := &fakeRunner{}
	args := []string{"run", "--name", "test", "--image", "example/royd:test", "--volume", "test-data", "--port", "127.0.0.1:5560:5555"}
	if err := execute(runner, args); err != nil {
		t.Fatal(err)
	}
	assertSingleCall(t, runner, []string{
		"run", "-d", "--privileged", "--name", "test",
		"--label", "org.royd.instance=true",
		"-v", "test-data:/data",
		"-p", "127.0.0.1:5560:5555",
		"example/royd:test",
	})
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
