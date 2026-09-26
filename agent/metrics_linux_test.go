//go:build linux

//
//  File:      metrics_linux_test.go
//  Created:   2026-09-27
//  Updated:   2026-09-27
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Tests for which /proc/mounts entries count as this machine's storage.
//  Notes:     Linux-only, like the reader under test. From a Mac, build the test binary with
//             `GOOS=linux go test -c` and run it on a Linux box. The rows are taken from real
//             machines: a Synology DS923+ (DSM 7, systemd 219) and an Ubuntu 24.04 desktop.
//
package main

import "testing"

func TestIsStorageMount(t *testing.T) {
	cases := []struct {
		name                  string
		device, mount, fsType string
		want                  bool
	}{
		// Synology DS923+
		{"DSM data volume", "/dev/mapper/cachedev_0", "/volume1", "btrfs", true},
		{"DSM system partition", "/dev/md0", "/", "ext4", true},
		// A 27 MB ext4 image DSM mounts for its auth service. It passed the type check and showed on
		// the storage card as a 0.0 TB disk.
		{"DSM loop-mounted image", "/dev/loop0", "/tmp/SynologyAuthService", "ext4", false},

		// Ubuntu
		{"ext4 root", "/dev/nvme0n1p2", "/", "ext4", true},
		{"snap", "/dev/loop12", "/snap/core22/1612", "squashfs", false},
		{"tmpfs", "tmpfs", "/run", "tmpfs", false},

		// Containers
		{"container root overlay", "overlay", "/", "overlay", true},
		{"overlay elsewhere", "overlay", "/var/lib/docker/overlay2/x/merged", "overlay", false},
	}
	for _, c := range cases {
		if got := isStorageMount(c.device, c.mount, c.fsType); got != c.want {
			t.Errorf("%s: isStorageMount(%q, %q, %q) = %v, want %v", c.name, c.device, c.mount, c.fsType, got, c.want)
		}
	}
}
