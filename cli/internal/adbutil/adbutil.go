package adbutil

import (
	"fmt"
	"os"
	"os/exec"
)

type Runner interface {
	Run(args ...string) error
}

type ExecRunner struct{}

func (ExecRunner) Run(args ...string) error {
	if _, err := exec.LookPath("adb"); err != nil {
		return fmt.Errorf("adb not found in PATH")
	}
	cmd := exec.Command("adb", args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.Stdin = os.Stdin
	return cmd.Run()
}
