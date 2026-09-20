package main

import (
	"flag"
	"fmt"
	"os"
	"strings"

	"github.com/royd-dev/royd/cli/internal/dockerutil"
	"github.com/royd-dev/royd/cli/internal/doctor"
)

const version = "0.1.0-dev"

type runConfig struct {
	image  string
	name   string
	volume string
	port   string
}

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(1)
	}

	runner := dockerutil.ExecRunner{}

	switch os.Args[1] {
	case "doctor":
		runDoctor()
	case "run":
		if err := runContainer(runner, os.Args[2:]); err != nil {
			exitWithError(err)
		}
	case "ps":
		if err := runner.Run("ps", "--filter", "label=org.royd.instance=true"); err != nil {
			exitWithError(err)
		}
	case "logs":
		if err := runLogs(runner, os.Args[2:]); err != nil {
			exitWithError(err)
		}
	case "version":
		fmt.Println(version)
	case "help", "-h", "--help":
		usage()
	default:
		usage()
		exitWithError(fmt.Errorf("unknown command: %s", os.Args[1]))
	}
}

func runDoctor() {
	report := doctor.Generate()
	fmt.Printf("royd doctor\n")
	fmt.Printf("OS: %s\n", report.OS)
	fmt.Printf("Arch: %s\n", report.Arch)
	for _, check := range report.Checks {
		fmt.Printf("- %s: %s - %s\n", check.Name, check.Status, check.Details)
	}
	fmt.Printf("Summary: %s\n", report.Summary)
}

func runContainer(runner dockerutil.Runner, args []string) error {
	cfg := runConfig{}
	fs := flag.NewFlagSet("run", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	fs.StringVar(&cfg.image, "image", "royd:dev", "Docker image to run")
	fs.StringVar(&cfg.name, "name", "royd", "Container name")
	fs.StringVar(&cfg.volume, "volume", "royd-data", "Docker volume to mount at /data")
	fs.StringVar(&cfg.port, "port", "127.0.0.1:5555:5555", "Port mapping for ADB")
	if err := fs.Parse(args); err != nil {
		return err
	}

	dockerArgs := []string{
		"run",
		"--privileged",
		"--name", cfg.name,
		"--label", "org.royd.instance=true",
		"-v", cfg.volume + ":/data",
		"-p", cfg.port,
	}
	if extra := fs.Args(); len(extra) > 0 {
		dockerArgs = append(dockerArgs, extra...)
	}
	dockerArgs = append(dockerArgs, cfg.image)
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

func usage() {
	fmt.Fprintf(os.Stderr, "royd is an optional CLI for local royd container workflows.\n\n")
	fmt.Fprintf(os.Stderr, "Usage:\n")
	fmt.Fprintf(os.Stderr, "  royd <command> [options]\n\n")
	fmt.Fprintf(os.Stderr, "Commands:\n")
	fmt.Fprintf(os.Stderr, "  doctor   Run lightweight host checks\n")
	fmt.Fprintf(os.Stderr, "  run      Run a royd container through Docker\n")
	fmt.Fprintf(os.Stderr, "  ps       List royd-labelled containers\n")
	fmt.Fprintf(os.Stderr, "  logs     Follow container logs\n")
	fmt.Fprintf(os.Stderr, "  version  Print the CLI version\n")
	fmt.Fprintf(os.Stderr, "  help     Show this help\n\n")
	fmt.Fprintf(os.Stderr, "Examples:\n")
	fmt.Fprintf(os.Stderr, "  royd doctor\n")
	fmt.Fprintf(os.Stderr, "  royd run --name royd-test --image royd:dev\n")
	fmt.Fprintf(os.Stderr, "  royd logs royd\n")
	fmt.Fprintf(os.Stderr, "  royd ps\n")
	fmt.Fprintf(os.Stderr, "\n")
	fmt.Fprintf(os.Stderr, "Run options are passed before the image, with additional docker run flags accepted before the image if needed.\n")
	fmt.Fprintf(os.Stderr, "Example: %s\n", strings.TrimSpace("royd run --name royd-test --image royd:dev --rm"))
}

func exitWithError(err error) {
	fmt.Fprintln(os.Stderr, err)
	os.Exit(1)
}
