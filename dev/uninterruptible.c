# Create a process in uninterruptible sleep state that forks a child process.
# Killing child process will change childs's state to zombie.
# Useful for WaitforTaskCompletion tests

int main() {
    vfork();
    sleep(180);
    return 0;
}
