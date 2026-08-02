package tmux

import (
	"fmt"
	"os/exec"
	"strings"
)

// NewSession creates a new detached tmux session with the given name and
// optional working directory. Returns the session name on success.
func NewSession(name, workDir string) error {
	args := []string{"new-session", "-d", "-s", name}
	if workDir != "" {
		args = append(args, "-c", workDir)
	}
	cmd := exec.Command("tmux", args...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("tmux new-session: %w (output: %s)", err, string(out))
	}
	return nil
}

// NewWindow creates a new window in the given tmux session.
// Returns the window index string (e.g. "1").
func NewWindow(session, name, workDir string) (string, error) {
	// get the current window count to predict the new index
	count, err := windowCount(session)
	if err != nil {
		return "", fmt.Errorf("tmux window-count: %w", err)
	}

	args := []string{"new-window", "-t", session}
	if name != "" {
		args = append(args, "-n", name)
	}
	if workDir != "" {
		args = append(args, "-c", workDir)
	}

	cmd := exec.Command("tmux", args...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("tmux new-window: %w (output: %s)", err, string(out))
	}

	return fmt.Sprintf("%d", count), nil
}

// SendKeys sends the given command to the specified window in a tmux session.
func SendKeys(session, window, command string) error {
	args := []string{"send-keys", "-t", fmt.Sprintf("%s:%s", session, window), command, "Enter"}
	cmd := exec.Command("tmux", args...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("tmux send-keys: %w (output: %s)", err, string(out))
	}
	return nil
}

// KillSession kills a tmux session by name.
func KillSession(name string) error {
	cmd := exec.Command("tmux", "kill-session", "-t", name)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("tmux kill-session: %w (output: %s)", err, string(out))
	}
	return nil
}

// KillWindow kills a specific window in a tmux session.
func KillWindow(session, window string) error {
	cmd := exec.Command("tmux", "kill-window", "-t", fmt.Sprintf("%s:%s", session, window))
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("tmux kill-window: %w (output: %s)", err, string(out))
	}
	return nil
}

// HasSession checks if a tmux session with the given name exists.
func HasSession(name string) bool {
	cmd := exec.Command("tmux", "has-session", "-t", name)
	return cmd.Run() == nil
}

// ListSessions returns all running tmux session names.
func ListSessions() ([]string, error) {
	cmd := exec.Command("tmux", "list-sessions", "-F", "#{session_name}")
	out, err := cmd.Output()
	if err != nil {
		// no sessions is not an error
		if exitErr, ok := err.(*exec.ExitError); ok && exitErr.ExitCode() == 1 {
			return nil, nil
		}
		return nil, fmt.Errorf("tmux list-sessions: %w", err)
	}
	lines := strings.Split(strings.TrimSpace(string(out)), "\n")
	if len(lines) == 1 && lines[0] == "" {
		return nil, nil
	}
	return lines, nil
}

// AttachInfo returns information needed to attach to a tmux session.
// This includes the session name, so the SwiftUI app can use it to spawn
// a PTY with "tmux attach -t <session>".
func AttachInfo(session string) map[string]string {
	return map[string]string{
		"session_name": session,
		"attach_cmd":   fmt.Sprintf("tmux attach -t %s", session),
	}
}

// PanePID returns the PID of the first pane in the given window.
func PanePID(session, window string) (int, error) {
	target := fmt.Sprintf("%s:%s.0", session, window)
	cmd := exec.Command("tmux", "display-message", "-p", "-t", target, "#{pane_pid}")
	out, err := cmd.Output()
	if err != nil {
		return 0, fmt.Errorf("tmux display-message pane_pid: %w", err)
	}
	var pid int
	if _, err := fmt.Sscanf(strings.TrimSpace(string(out)), "%d", &pid); err != nil {
		return 0, fmt.Errorf("parse pane pid: %w", err)
	}
	return pid, nil
}

// PaneIsAlive checks if the pane (process) is still running.
func PaneIsAlive(session, window string) bool {
	target := fmt.Sprintf("%s:%s.0", session, window)
	cmd := exec.Command("tmux", "display-message", "-p", "-t", target,
		"#{pane_dead}")
	out, err := cmd.Output()
	if err != nil {
		return false
	}
	return strings.TrimSpace(string(out)) == "0"
}

// CapturePane grabs the visible content from a pane.
func CapturePane(session, window string) (string, error) {
	target := fmt.Sprintf("%s:%s.0", session, window)
	cmd := exec.Command("tmux", "capture-pane", "-p", "-t", target, "-S", "-20")
	out, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("tmux capture-pane: %w", err)
	}
	return string(out), nil
}

// SanitizeName converts a string into a tmux-safe session name.
// tmux session names cannot contain '.' or ':'.
func SanitizeName(name string) string {
	r := strings.NewReplacer(".", "_", ":", "_", "/", "_", " ", "_")
	return r.Replace(name)
}

func windowCount(session string) (int, error) {
	cmd := exec.Command("tmux", "list-windows", "-t", session)
	out, err := cmd.Output()
	if err != nil {
		return 0, err
	}
	lines := strings.Split(strings.TrimSpace(string(out)), "\n")
	if len(lines) == 1 && lines[0] == "" {
		return 0, nil
	}
	return len(lines), nil
}
