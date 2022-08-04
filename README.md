# Alfred

Alfred is a debugging utility created on top of the de-facto golang debugger, Delve. It allows the user to, seamlessly:
 * **inject** Delve into the target container that's running the target binary (that needs to be debugged),
 * **attach** in-cluster Delve to the target process,
 * **relay** debugging information to the user's local Delve instance (IDE or terminal),
 * **debug** the target process,
 * **rebuild** on any changes to the Dockerfile's parent directory, and
 * **clean up** all generated artefacts and orphan processes on interruption or exit.

### Prerequisites

* [`delve`](https://command-not-found.com/dlv)
* [`kubectl`](https://command-not-found.com/kubectl)

All above prerequisites will be installed if they are not already present. In addition to these, the following are assumed to be installed on the user's machine,

* [`awk`](https://command-not-found.com/awk)
* [`curl`](https://command-not-found.com/curl)
* [`jq`](https://command-not-found.com/jq)
* [`md5sum`](https://command-not-found.com/md5sum)
* [`stty`](https://command-not-found.com/stty)

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

<details>
<summary>initial-build (v0.0.1)</summary>

https://user-images.githubusercontent.com/33557095/182026204-50179f87-4ef5-4781-a0ba-114060427bfd.mp4

</details>
<details>
<summary>lazarus (v0.1.0)</summary>

https://user-images.githubusercontent.com/33557095/183291207-7303d282-656e-4311-96a4-ceab39ab3a71.mp4

</details>

</details>

### Installation

```bash
# point a global binary to the alfred script, for inter-project convenience.
ln -s ${PWD}/alfred.sh /usr/local/bin/alfred
```

### Feature status

* [**Todo**] Profile the script to detect potential performance bottlenecks.
* [**Todo**] Allow `.alfredrc` configuration files so the user does not need to pass in the same arguments everytime, which they
  can define in the project root (or `~/.config/`).
* [**Done**] Watch the parent directory for changes, automate the creation of a corresponding debug image and it's injection into
  the CSV, so that the entire workflow can be truly automated.

### Trivia

> What led to the incubation of this project?

This project started out as a question (a thread) on [`r/kubernetes`](https://www.reddit.com/r/kubernetes/comments/w6tsmf/q_debugger_injection_possibilities/?utm_source=share&utm_medium=web2x&context=3) and the idea was pivoted twice (binary `ConfigMap`s to `emptyDir`, and `emptyDir` to finally, `kubectl *`) since then. I plan on continuing to make this more efficient in terms of usability and performance, as I get more feedback over time.

> Why bash?

Initially, this started out as a Golang project, [lazarus](https://github.com/rexagod/lazarus), but soon pivoted to a bash utility since there's a plethora of production-grade utilities already available in `kubectl` that are directly relevant to this project and which it can utilize in a flexible manner. If binary `ConfigMap`s or `emptyDir`s were at the core of this, the preference would have easily been Go.

### LICENSE

[GNU AFFERO GENERAL PUBLIC LICENSE, Version 3, 19 November 2007](./LICENSE)
