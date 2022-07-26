# Alfred

Alfred is a debugging utility created on top of the de-facto golang debugger, Delve. It allows the user to, seamlessly:
 * **inject** Delve into the target container that's running the target binary (that needs to be debugged),
 * **attach** in-cluster Delve to the target process,
 * **relay** debugging information to the user's local Delve instance (IDE or terminal),
 * **clean up** all generated artefacts and orphan processes on interruption or exit.

### Prerequisites

* [`kubectl`](https://kubernetes.io/docs/tasks/tools/install-kubectl/)
* [`delve`](https://github.com/go-delve/delve/releases)

All prerequisites will be installed if they are not already present.

### Usage

Alfred can be used in the following ways:
* IDE: Create a remote golang debugger configuration in your respective IDE, that points to the forwarded port (`--port`).
  * NOTE: Most IDEs assume same `--target-port` and `--port` values.

<details>
<summary>Screenshot</summary>

![./assets/ide-configuration.png](./assets/ide-configuration.png)

</details>

* Terminal: Connect to the forwarded debugging port in the in-cluster environment using the command below.
  * `dlv connect "127.0.0.1:${PORT}" --accept-multiclient --api-version 2 --check-go-version --headless --only-same-user false`

### Demonstration

The repository used to test out the debugger, and to record the demonstration below is
[`red-hat-storage/mcg-osd-deployer`](https://github.com/red-hat-storage/mcg-osd-deployer).

<details>
<summary>Screencast</summary>

https://user-images.githubusercontent.com/33557095/182026204-50179f87-4ef5-4781-a0ba-114060427bfd.mp4

</details>

### TODOs

* Allow `.alfredrc` configuration files so the user does not need to pass in the same arguments everytime, which they
  can define in the project root (or `~/.config/`).
* Watch the parent directory for changes, automate the creation of a corresponding debug image and it's injection into
  the CSV, so that the entire workflow can be truly automated.

### Trivia

This project started out as a thread in [`r/kubernetes`](https://www.reddit.com/r/kubernetes/comments/w6tsmf/q_debugger_injection_possibilities/?utm_source=share&utm_medium=web2x&context=3) and the idea was pivoted twice (`Binary ConfigMaps` to `emptyDir`, and `emptyDir` to `kubectl cp`) since then. I plan on continuing to make this more efficient in terms of usability and performance, as I get more feedback over time.

### LICENSE

[GNU AFFERO GENERAL PUBLIC LICENSE, Version 3, 19 November 2007](./LICENSE)
