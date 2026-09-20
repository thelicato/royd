package main

import (
	"flag"
	"fmt"
	"os"

	"github.com/royd-dev/royd/cli/internal/dockerutil"
	"github.com/royd-dev/royd/cli/internal/doctor"
)

const version = "0.1.0-dev"

type runConfig struct {
	image    string
	name     string
	volume   string
	port     string
	memory   string
	width    int
	height   int
	dpi      int
	fps      int
	security string
}

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(1)
	}

	runner := dockerutil.ExecRunner{}
	if err := execute(runner, os.Args[1:]); err != nil {
		exitWithError(err)
	}
}

func execute(runner dockerutil.Runner, args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("command required")
	}

	switch args[0] {
	case "doctor":
		return runDoctor()
	case "run":
		return runContainer(runner, args[1:])
	case "ps":
		return runner.Run("ps", "-a", "--filter", "label=org.royd.instance=true")
	case "logs":
		return runLogs(runner, args[1:])
	case "shell":
		return runShell(runner, args[1:])
	case "stop":
		return runStop(runner, args[1:])
	case "rm":
		return runRemove(runner, args[1:])
	case "version":
		fmt.Println(version)
		return nil
	case "help", "-h", "--help":
		usage()
		return nil
	default:
		usage()
		return fmt.Errorf("unknown command: %s", args[0])
	}
}

func runDoctor() error {
	report := doctor.Generate()
	fmt.Printf("royd doctor\n")
	fmt.Printf("OS: %s\n", report.OS)
	fmt.Printf("Arch: %s\n", report.Arch)
	for _, check := range report.Checks {
		fmt.Printf("- %s: %s - %s\n", check.Name, check.Status, check.Details)
	}
	fmt.Printf("Summary: %s\n", report.Summary)
	if report.HasErrors() {
		return fmt.Errorf("host requirements are not satisfied")
	}
	return nil
}

func runContainer(runner dockerutil.Runner, args []string) error {
	cfg := runConfig{}
	fs := flag.NewFlagSet("run", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	fs.StringVar(&cfg.image, "image", "royd:dev", "Docker image to run")
	fs.StringVar(&cfg.name, "name", "royd", "Container name")
	fs.StringVar(&cfg.volume, "volume", "royd-data", "Docker volume to mount at /data")
	fs.StringVar(&cfg.port, "port", "127.0.0.1:5555:5555", "Port mapping for ADB")
	fs.StringVar(&cfg.memory, "memory", "", "Optional Docker memory limit, for example 768m")
	fs.IntVar(&cfg.width, "width", 540, "Android display width")
	fs.IntVar(&cfg.height, "height", 960, "Android display height")
	fs.IntVar(&cfg.dpi, "dpi", 240, "Android display density")
	fs.IntVar(&cfg.fps, "fps", 30, "Android display frame rate")
	fs.StringVar(&cfg.security, "security", "privileged", "Runtime security mode: privileged or experimental")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 0 {
		return fmt.Errorf("unexpected run arguments: %v", fs.Args())
	}

	if cfg.width <= 0 || cfg.height <= 0 || cfg.dpi <= 0 || cfg.fps <= 0 {
		return fmt.Errorf("display values must be positive integers")
	}
	dockerArgs := []string{"run", "-d"}
	switch cfg.security {
	case "privileged":
		dockerArgs = append(dockerArgs, "--privileged")
	case "experimental":
		for _, capability := range []string{"SYS_ADMIN", "NET_ADMIN", "SYS_NICE", "SYS_RESOURCE", "SYS_PTRACE"} {
			dockerArgs = append(dockerArgs, "--cap-add="+capability)
		}
	default:
		return fmt.Errorf("unknown security mode: %s", cfg.security)
	}
	dockerArgs = append(dockerArgs,
		"--name", cfg.name,
		"--label", "org.royd.instance=true",
		"-v", cfg.volume+":/data",
		"-p", cfg.port,
	)
	if cfg.memory != "" {
		dockerArgs = append(dockerArgs, "--memory", cfg.memory, "--memory-swap", cfg.memory)
	}
	dockerArgs = append(dockerArgs,
		cfg.image,
		fmt.Sprintf("androidboot.royd_width=%d", cfg.width),
		fmt.Sprintf("androidboot.royd_height=%d", cfg.height),
		fmt.Sprintf("androidboot.royd_dpi=%d", cfg.dpi),
		fmt.Sprintf("androidboot.royd_fps=%d", cfg.fps),
	)
	return runner.Run(dockerArgs...)
}

func runLogs(runner dockerutil.Runner, args []string) error {
	fs := flag.NewFlagSet("logs", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	follow := fs.Bool("f", true, "Follow logs")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 1 {
		return fmt.Errorf("usage: royd logs [--f=true] <container>")
	}
	dockerArgs := []string{"logs"}
	if *follow {
		dockerArgs = append(dockerArgs, "-f")
	}
	dockerArgs = append(dockerArgs, fs.Arg(0))
	return runner.Run(dockerArgs...)
}

func runShell(runner dockerutil.Runner, args []string) error {
	if len(args) != 1 {
		return fmt.Errorf("usage: royd shell <container>")
	}
	return runner.Run("exec", "-it", args[0], "/system/bin/sh")
}

func runStop(runner dockerutil.Runner, args []string) error {
	if len(args) != 1 {
		return fmt.Errorf("usage: royd stop <container>")
	}
	return runner.Run("stop", args[0])
}

func runRemove(runner dockerutil.Runner, args []string) error {
	fs := flag.NewFlagSet("rm", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	force := fs.Bool("f", false, "Force removal of a running container")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 1 {
		return fmt.Errorf("usage: royd rm [-f] <container>")
	}
	dockerArgs := []string{"rm"}
	if *force {
		dockerArgs = append(dockerArgs, "-f")
	}
	dockerArgs = append(dockerArgs, fs.Arg(0))
	return runner.Run(dockerArgs...)
}

func usage() {
	fmt.Fprintf(os.Stderr, "royd is an optional CLI for local royd container workflows.\n\n")
	fmt.Fprintf(os.Stderr, "Usage:\n")
	fmt.Fprintf(os.Stderr, "  royd <command> [options]\n\n")
	fmt.Fprintf(os.Stderr, "Commands:\n")
	fmt.Fprintf(os.Stderr, "  doctor   Run lightweight host checks\n")
	fmt.Fprintf(os.Stderr, "  run      Start a royd container through Docker\n")
	fmt.Fprintf(os.Stderr, "  ps       List royd-labelled containers\n")
	fmt.Fprintf(os.Stderr, "  logs     Follow container logs\n")
	fmt.Fprintf(os.Stderr, "  shell    Open an Android shell in a container\n")
	fmt.Fprintf(os.Stderr, "  stop     Stop a container\n")
	fmt.Fprintf(os.Stderr, "  rm       Remove a container\n")
	fmt.Fprintf(os.Stderr, "  version  Print the CLI version\n")
	fmt.Fprintf(os.Stderr, "  help     Show this help\n\n")
	fmt.Fprintf(os.Stderr, "Examples:\n")
	fmt.Fprintf(os.Stderr, "  royd doctor\n")
	fmt.Fprintf(os.Stderr, "  royd run --name royd-test --image royd:dev --memory 768m\n")
	fmt.Fprintf(os.Stderr, "  royd run --security experimental --name royd-test\n")
	fmt.Fprintf(os.Stderr, "  royd logs royd\n")
	fmt.Fprintf(os.Stderr, "  royd shell royd\n")
	fmt.Fprintf(os.Stderr, "  royd stop royd\n")
	fmt.Fprintf(os.Stderr, "  royd rm royd\n")
}

func exitWithError(err error) {
	fmt.Fprintln(os.Stderr, err)
	os.Exit(1)
}
