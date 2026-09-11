package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestDataDirDefault(t *testing.T) {
	home, _ := os.UserHomeDir()
	want := filepath.Join(home, ".lmux")
	if got := DataDir(); got != want {
		t.Errorf("DataDir() = %q, want %q", got, want)
	}
}

func TestDataDirEnvOverride(t *testing.T) {
	t.Setenv("LMUX_DATA_DIR", "/tmp/lmux-demo")
	if got := DataDir(); got != "/tmp/lmux-demo" {
		t.Errorf("DataDir() = %q, want env override", got)
	}
	if got := DefaultConfigPath(); got != "/tmp/lmux-demo/config.json" {
		t.Errorf("DefaultConfigPath() = %q, want /tmp/lmux-demo/config.json", got)
	}
}

func TestDefaultPort(t *testing.T) {
	if got := defaultPort(); got != 19680 {
		t.Errorf("defaultPort() = %d, want 19680", got)
	}
	t.Setenv("LMUX_PORT", "19681")
	if got := defaultPort(); got != 19681 {
		t.Errorf("defaultPort() with env = %d, want 19681", got)
	}
	for _, bad := range []string{"0", "-1", "abc", "70000"} {
		t.Setenv("LMUX_PORT", bad)
		if got := defaultPort(); got != 19680 {
			t.Errorf("defaultPort() with %q = %d, want fallback 19680", bad, got)
		}
	}
}

// A side-by-side instance must not rewrite the real config's data dir/port.
func TestLoadEnvOverridesOnDiskConfig(t *testing.T) {
	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "config.json")
	if err := os.WriteFile(cfgPath, []byte(`{"port":19680,"token":"t","data_dir":"/real/.lmux"}`), 0o600); err != nil {
		t.Fatal(err)
	}

	t.Setenv("LMUX_DATA_DIR", "/tmp/lmux-demo")
	t.Setenv("LMUX_PORT", "19681")
	cfg, err := Load(cfgPath)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.DataDir != "/tmp/lmux-demo" {
		t.Errorf("DataDir = %q, want env override", cfg.DataDir)
	}
	if cfg.Port != 19681 {
		t.Errorf("Port = %d, want env override 19681", cfg.Port)
	}
	if cfg.Token != "t" {
		t.Errorf("Token = %q, want on-disk value preserved", cfg.Token)
	}
}
