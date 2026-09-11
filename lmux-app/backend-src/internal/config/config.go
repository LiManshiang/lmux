package config

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
)

// Config holds the runtime configuration.
type Config struct {
	Port    int    `json:"port"`
	Token   string `json:"token"`
	DataDir string `json:"data_dir"`
}

// DataDir returns the base directory for lmux runtime data (~/.lmux by
// default). The LMUX_DATA_DIR environment variable overrides it so a second
// instance — a demo/screenshot run, an integration test, or CI — can run
// side by side with the real one without touching its sessions.
func DataDir() string {
	if dir := os.Getenv("LMUX_DATA_DIR"); dir != "" {
		return dir
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".lmux")
}

// Default returns a config with sensible defaults.
func Default() *Config {
	return &Config{
		Port:    defaultPort(),
		DataDir: DataDir(),
		Token:   generateToken(),
	}
}

// defaultPort returns LMUX_PORT when set and valid, otherwise the standard
// backend port. Keeps side-by-side instances from colliding on 19680.
func defaultPort() int {
	if v := os.Getenv("LMUX_PORT"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 && n < 65536 {
			return n
		}
	}
	return 19680
}

// Load reads config from the given path, falling back to defaults.
func Load(path string) (*Config, error) {
	cfg := Default()

	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			// first run: save defaults
			if err := cfg.Save(path); err != nil {
				return cfg, nil
			}
			return cfg, nil
		}
		return cfg, fmt.Errorf("read config: %w", err)
	}

	if err := json.Unmarshal(data, cfg); err != nil {
		return cfg, fmt.Errorf("parse config: %w", err)
	}

	// Environment overrides win over the on-disk config so a side-by-side
	// instance (demo/CI) can point at its own directory and port without
	// rewriting the real config.json.
	if dir := os.Getenv("LMUX_DATA_DIR"); dir != "" {
		cfg.DataDir = dir
	}
	cfg.Port = defaultPort()

	return cfg, nil
}

// Save writes the config to disk.
func (c *Config) Save(path string) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return fmt.Errorf("create config dir: %w", err)
	}

	data, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal config: %w", err)
	}

	return os.WriteFile(path, data, 0600)
}

// DefaultConfigPath returns the default config file path.
func DefaultConfigPath() string {
	return filepath.Join(DataDir(), "config.json")
}

func generateToken() string {
	b := make([]byte, 16)
	rand.Read(b)
	return hex.EncodeToString(b)
}
