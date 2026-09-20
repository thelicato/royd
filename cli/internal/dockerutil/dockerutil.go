package dockerutil

import (
	"fmt"
	"os"
	"os/exec"
)

type Runner interface {
	Run(args ...string) error
	Output(args ...string) ([]byte, error)
}

type ExecRunner struct{}

func (ExecRunner) Run(args ...string) error {
	cmd := exec.Command("docker", args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.Stdin = os.Stdin
	return cmd.Run()
}

func (ExecRunner) Output(args ...string) ([]byte, error) {
	cmd := exec.Command("docker", args...)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("docker %v: %w\n%s", args, err, string(output))
	}
	return output, nil
}
