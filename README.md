# vagrant-rpi-armhf

A pre-built Raspberry Pi OS armhf (32-bit) Vagrant box for QEMU, designed for Apple Silicon Macs.

Develop and test Raspberry Pi software on your Mac without physical hardware. No ARM32 RPi Vagrant box exists for the vagrant-qemu provider — this project fills that gap.

## Prerequisites

- [QEMU](https://www.qemu.org/): `brew install qemu`
- [Vagrant](https://www.vagrantup.com/): `brew install hashicorp/tap/hashicorp-vagrant`
- [vagrant-qemu](https://github.com/ppggff/vagrant-qemu) plugin: `vagrant plugin install vagrant-qemu`

## Quick start

```bash
vagrant init christhomas/rpi-armhf
vagrant up --provider=qemu
vagrant ssh
```

Or use the included `Vagrantfile`:

```bash
git clone https://github.com/christhomas/vagrant-rpi-armhf.git
cd vagrant-rpi-armhf
vagrant up
vagrant ssh
```

## Shared folders

The box does not mount a synced folder by default. Two options are available:

### Option 1: virtiofsd (recommended)

Near-native performance via the FUSE-based virtio-fs protocol. Requires a patched QEMU build with virtiofsd support:

```bash
brew install christhomas/tap/qemu-virtiofs
```

This requires running virtiofsd in a separate terminal and passing the appropriate socket to QEMU. See the [virtiofsd documentation](https://virtio-fs.gitlab.io/) for details.

### Option 2: 9p (simpler, slower)

Add 9p filesystem passthrough via `extra_qemu_args` in your Vagrantfile:

```ruby
Vagrant.configure("2") do |config|
  config.vm.box = "christhomas/rpi-armhf"
  config.vm.box_architecture = "arm"

  config.vm.provider "qemu" do |qe|
    qe.arch = "arm"
    qe.machine = "virt"
    qe.cpu = "cortex-a7"
    qe.memory = "512M"
    qe.net_device = "virtio-net-device"
    qe.ssh_port = 50022
    qe.extra_qemu_args = [
      "-fsdev", "local,id=fsdev0,path=/path/to/share,security_model=none",
      "-device", "virtio-9p-device,fsdev=fsdev0,mount_tag=shared",
    ]
  end

  config.vm.synced_folder ".", "/vagrant", disabled: true
end
```

Then mount inside the guest:

```bash
sudo mount -t 9p -o trans=virtio,version=9p2000.L shared /mnt
```

## What's different from stock Raspberry Pi OS

| Change | Reason |
|--------|--------|
| Debian `linux-image-armmp-lpae` kernel | The stock RPi kernel lacks virtio drivers needed for QEMU `virt` machine |
| Initramfs rebuilt with virtio modules | `virtio_mmio`, `virtio_blk`, `virtio_net`, `virtio_pci` for QEMU device support |
| `vagrant` user added | Vagrant convention: passwordless sudo, insecure key SSH |
| SSH enabled | Required for `vagrant ssh` |
| RPi kernel/firmware removed | Not needed in QEMU; saves ~200MB |
| Docs/man/locales stripped | Smaller box size |

The userland is still Raspberry Pi OS (Debian bookworm armhf) — all `apt` packages from the RPi repositories work as expected.

## Building from source

The build process has 5 phases:

1. **Phase 1** (macOS): Download RPi OS armhf lite image, decompress, convert to qcow2, resize to 4GB
2. **Phase 2** (macOS): Prepare the customization script
3. **Phase 3** (Linux VM): Run `vm-customize.sh` inside a Linux VM with nbd/chroot support to install the Debian kernel, create the vagrant user, and configure SSH
4. **Phase 4** (macOS): Compact qcow2, package as `.box` with metadata
5. **Phase 5** (macOS): Add box to local Vagrant

```bash
cd build
./build-box.sh
```

### Phase 3 Linux VM requirements

The customization script must run inside a Linux VM (aarch64 or x86_64) with:

- `qemu-nbd` and the `nbd` kernel module
- `qemu-arm-static` (for armhf chroot)
- `sfdisk`, `resize2fs`, `chroot`

On Ubuntu/Debian:

```bash
sudo apt-get install qemu-utils qemu-user-static nbd-client parted e2fsprogs
```

## Technical details

- **Architecture**: ARM 32-bit (armhf)
- **Machine type**: QEMU `virt` with `cortex-a7` CPU
- **Emulation**: TCG (software emulation) — no KVM on Apple Silicon for 32-bit ARM
- **Kernel**: Debian `armmp-lpae` (external boot via `-kernel` / `-initrd`)
- **Base image**: Raspberry Pi OS Lite (bookworm, armhf)
- **Default memory**: 512MB
- **Disk**: 4GB qcow2 (expandable)

## License

[MIT](LICENSE)
