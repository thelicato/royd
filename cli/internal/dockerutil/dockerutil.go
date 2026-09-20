package dockerutil

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
)

type Runner interface {
	Run(args ...string) error
	Output(args ...string) ([]byte, error)
}

type ExecRunner struct{}

func (ExecRunner) Run(args ...string) error {
	printCommand(args...)
	cmd := exec.Command("docker", args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.Stdin = os.Stdin
	return cmd.Run()
}

func (ExecRunner) Output(args ...string) ([]byte, error) {
	printCommand(args...)
	cmd := exec.Command("docker", args...)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("docker %v: %w\n%s", args, err, string(output))
	}
	return output, nil
}

func FormatCommand(args ...string) string {
	parts := []string{"docker"}
	for _, arg := range args {
		parts = append(parts, shellQuote(arg))
	}
	return strings.Join(parts, " ")
}

func printCommand(args ...string) {
	fmt.Fprintf(os.Stderr, "$ %s\n", FormatCommand(args...))
}

func shellQuote(value string) string {
	if value == "" {
		return "''"
	}
	if !strings.ContainsAny(value, " \t\n'\"\\$`!&|;<>*?()[]{}") {
		return value
	}
	return "'" + strings.ReplaceAll(value, "'", "'\\''") + "'"
}
