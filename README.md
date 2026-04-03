# vagrant-rpi-bookworm-armhf

Raspberry Pi OS Bookworm armhf (32-bit) Vagrant box for QEMU.

ARM32 emulation via TCG — no hardware acceleration available for 32-bit ARM
on Apple Silicon or x86. Develop and test Raspberry Pi ARM32 software without
physical hardware.

The RPi OS disk image is left untouched — only vagrant user, SSH, networking,
and growroot are added. A Debian armmp-lpae kernel is provided externally
for QEMU virtio support. The image can still be written to an SD card
for use on real Raspberry Pi hardware.

## Prerequisites

```bash
brew tap antimatter-studios/tap
brew install antimatter-studios/tap/vagrant-qemu
```

This installs QEMU (with virtiofs support), virtiofsd, and the vagrant-qemu plugin.

## Quick start

```bash
vagrant box add christhomas/vagrant-rpi-bookworm-armhf \
  https://github.com/christhomas/vagrant-rpi-bookworm-armhf/releases/download/v1.0.0/rpi-armhf.box
```

Create a `Vagrantfile`:

```ruby
Vagrant.configure("2") do |config|
  config.vm.box = "christhomas/vagrant-rpi-bookworm-armhf"
  config.vm.box_architecture = "arm"
  config.vm.box_check_update = false
  config.vm.synced_folder ".", "/vagrant", type: "virtiofs"
end
```

```bash
vagrant up
vagrant ssh
```

## What's in the box

| Feature | Details |
|---------|---------|
| **Base image** | Raspberry Pi OS Lite Bookworm (armhf) |
| **Boot kernel** | Debian armmp-lpae (external via `-kernel`/`-initrd`) |
| **Emulation** | TCG software emulation (ARM32 on any host) |
| **Shared folders** | virtiofs with UID mapping (`pi` user ↔ host user) |
| **Disk expansion** | growroot service on first boot (set size via `qe.disk_resize`) |
| **Users** | `pi` (UID 1000, from RPi OS) + `vagrant` (UID 1001, Vagrant SSH) |

## Disk resize

The box ships with a small disk (~2.6GB). Set the size per-project:

```ruby
config.vm.provider "qemu" do |qe|
  qe.disk_resize = "8G"
end
```

The growroot service expands the partition on first boot.

## Building from source

On macOS (boots a build VM automatically):
```bash
./build-box.sh
```

On Linux (runs directly):
```bash
sudo ./build-linux.sh
```

The build process:
1. Downloads RPi OS armhf lite image
2. Downloads Debian armmp-lpae kernel (for virtio support)
3. Mounts image via nbd, chroots to add vagrant user, SSH, networking, growroot
4. Installs kernel modules on disk for post-boot driver loading (virtiofs)
5. Builds initrd inside the chroot (correct architecture binaries via qemu-arm-static)
6. Patches initrd with virtio insmod commands
7. Packages as `.box` with external kernel/initrd

## Testing

```bash
cd test/
vagrant up
./test-virtiofs.sh    # 14 tests: file visibility, creation, modification, deletion, UID mapping
```

## CI/CD

The GitHub Actions pipeline builds the box on Linux amd64, runs the full
virtiofs test suite, and publishes the `.box` to GitHub Releases on tag push.

## License

[MIT](LICENSE)
