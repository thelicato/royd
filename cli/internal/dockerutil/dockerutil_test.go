package dockerutil

import "testing"

func TestFormatCommand(t *testing.T) {
	got := FormatCommand("run", "--name", "royd test", "royd:dev")
	want := "docker run --name 'royd test' royd:dev"
	if got != want {
		t.Fatalf("unexpected command: %q, want %q", got, want)
	}
}

func TestFormatCommandQuotesSingleQuote(t *testing.T) {
	got := FormatCommand("exec", "royd", "echo", "it's ready")
	want := "docker exec royd echo 'it'\\''s ready'"
	if got != want {
		t.Fatalf("unexpected command: %q, want %q", got, want)
	}
}
