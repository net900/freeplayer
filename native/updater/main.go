// Command update replaces a running Free Player install and restarts it.
//
// The shell downloads the release zip, verifies its SHA-256, extracts it to a
// staging directory and starts this helper from a temporary copy, then exits.
// The helper waits for the old process to disappear (Windows refuses to
// overwrite a running executable), copies the staged tree over the install
// directory and relaunches the app.
package main

import (
	"flag"
	"io"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"time"
)

const waitObject0 = 0x00000000

func main() {
	pid := flag.Int("pid", 0, "process id of the running app")
	source := flag.String("source", "", "staged build directory")
	target := flag.String("target", "", "install directory")
	exe := flag.String("exe", "free_player.exe", "executable to restart")
	restart := flag.Bool("restart", true, "restart the app after replacing")
	wait := flag.Duration("wait", 90*time.Second, "how long to wait for the old process")
	flag.Parse()

	if f, err := os.OpenFile(
		filepath.Join(os.TempDir(), "freeplayer-update.log"),
		os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644,
	); err == nil {
		log.SetOutput(f)
		defer f.Close()
	}
	log.Printf("update start: pid=%d source=%s target=%s", *pid, *source, *target)

	if *source == "" || *target == "" {
		log.Fatal("update: --source and --target are required")
	}
	if *pid > 0 && !waitExit(uint32(*pid), *wait) {
		log.Fatalf("update: process %d is still running", *pid)
	}
	// Let the old process release its file handles.
	time.Sleep(700 * time.Millisecond)

	if err := copyTree(*source, *target); err != nil {
		log.Printf("update: replace failed: %v", err)
	} else {
		log.Printf("update: replace ok")
	}

	if *restart {
		exePath := filepath.Join(*target, *exe)
		log.Printf("update: restart %s", exePath)
		if err := start(exePath, *target); err != nil {
			log.Printf("update: restart failed: %v", err)
		}
	}

	if err := os.RemoveAll(*source); err != nil {
		log.Printf("update: cleanup failed: %v", err)
	}
	log.Printf("update: done")
}

// waitExit blocks until the process is gone. A process that cannot be opened
// is already gone.
func waitExit(pid uint32, timeout time.Duration) bool {
	handle, err := syscall.OpenProcess(syscall.SYNCHRONIZE, false, pid)
	if err != nil {
		return true
	}
	defer syscall.CloseHandle(handle)
	event, err := syscall.WaitForSingleObject(
		handle, uint32(timeout/time.Millisecond))
	return err == nil && event == waitObject0
}

func start(exePath, dir string) error {
	cmd := exec.Command(exePath)
	cmd.Dir = dir
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	return cmd.Start()
}

func copyTree(src, dst string) error {
	src = filepath.Clean(src)
	dst = filepath.Clean(dst)
	return filepath.Walk(src, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(src, path)
		if err != nil {
			return err
		}
		if rel == "." {
			return nil
		}
		out := filepath.Join(dst, rel)
		if info.IsDir() {
			return os.MkdirAll(out, 0o755)
		}
		if !info.Mode().IsRegular() {
			return nil
		}
		return copyFile(path, out)
	})
}

// copyFile retries because antivirus and the shell can hold a target file for
// a moment after the process exits.
func copyFile(src, dst string) error {
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	var last error
	for attempt := 0; attempt < 5; attempt++ {
		last = copyOnce(src, dst)
		if last == nil {
			return nil
		}
		time.Sleep(time.Duration(200*(attempt+1)) * time.Millisecond)
	}
	return last
}

// copyOnce writes to a sibling temp name first, so a failed copy never leaves
// a truncated executable behind.
func copyOnce(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	tmp := dst + ".new"
	out, err := os.Create(tmp)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		os.Remove(tmp)
		return err
	}
	if err := out.Close(); err != nil {
		os.Remove(tmp)
		return err
	}
	if err := os.Rename(tmp, dst); err != nil {
		os.Remove(tmp)
		return err
	}
	return nil
}
