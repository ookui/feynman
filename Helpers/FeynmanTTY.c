// macOS does not automatically acquire a controlling terminal on open(2).
// The parent creates a new session and supplies the PTY slave on descriptors 0–2.
#include <sys/ioctl.h>
#include <termios.h>
#include <stdio.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc < 2) return 2;
    if (ioctl(STDIN_FILENO, TIOCSCTTY, 0) == -1 ||
        tcsetpgrp(STDIN_FILENO, getpgrp()) == -1) {
        perror("Feynman terminal");
        return 1;
    }
    execv(argv[1], argv + 1);
    perror("Feynman terminal exec");
    return 1;
}
