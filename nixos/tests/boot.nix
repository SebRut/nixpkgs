{ system ? builtins.currentSystem,
  config ? {},
  pkgs ? import ../.. { inherit system config; }
}:

with import ../lib/testing-python.nix { inherit system pkgs; };
with pkgs.lib;

let
  qemu-common = import ../lib/qemu-common.nix { inherit (pkgs) lib pkgs; };

  iso =
    (import ../lib/eval-config.nix {
      inherit system;
      modules = [
        ../modules/installer/cd-dvd/installation-cd-minimal.nix
        ../modules/testing/test-instrumentation.nix
      ];
    }).config.system.build.isoImage;

  sd =
    (import ../lib/eval-config.nix {
      inherit system;
      modules = [
        ../modules/installer/sd-card/sd-image-x86_64.nix
        ../modules/testing/test-instrumentation.nix
        { sdImage.compressImage = false; }
      ];
    }).config.system.build.sdImage;

  pythonDict = params: "\n    {\n        ${concatStringsSep ",\n        " (mapAttrsToList (name: param: "\"${name}\": \"${param}\"") params)},\n    }\n";

  makeBootTest = name: extraConfig:
    let
      machineConfig = pythonDict ({
        qemuBinary = qemu-common.qemuBinary pkgs.qemu_test;
        qemuFlags = "-m 768";
      } // extraConfig);
    in
      makeTest {
        name = "boot-" + name;
        nodes = { };
        testScript =
          ''
            machine = create_machine(${machineConfig})
            machine.start()
            machine.wait_for_unit("multi-user.target")
            machine.succeed("nix store verify --no-trust -r --option experimental-features nix-command /run/current-system")

            with subtest("Check whether the channel got installed correctly"):
                machine.succeed("nix-instantiate --dry-run '<nixpkgs>' -A hello")
                machine.succeed("nix-env --dry-run -iA nixos.procps")

            machine.shutdown()
          '';
      };

  makeNetbootTest = name: extraConfig:
    let
      config = (import ../lib/eval-config.nix {
          inherit system;
          modules =
            [
              ../modules/installer/netboot/netboot-minimal.nix
              ../modules/testing/test-instrumentation.nix
              {
                system.nixos.revision = mkForce "constant-nixos-revision";
                documentation.enable = false;
              }
              {
                nix.settings = {
                  substituters = [ ];
                  hashed-mirrors = null;
                  connect-timeout = 1;
                };

                system.extraDependencies = with pkgs; [
                  curl
                  desktop-file-utils
                  docbook5
                  docbook_xsl_ns
                  kmod.dev
                  libarchive
                  libarchive.dev
                  libxml2.bin
                  libxslt.bin
                  python3Minimal
                  shared-mime-info
                  stdenv
                  sudo
                  xorg.lndir
                ];
              }
            ];
        }).config;
      ipxeBootDir = pkgs.symlinkJoin {
        name = "ipxeBootDir";
        paths = [
          config.system.build.netbootRamdisk
          config.system.build.kernel
          config.system.build.netbootIpxeScript
        ];
      };
    in
      makeTest {
        name = "boot-netboot-${name}";
        meta.maintainers = with pkgs.lib.maintainers; [ raitobezarius ];
        nodes.machine = {
          imports = [
            extraConfig
          ];

          # We *NEVER* want to use a Nix store image with a netboot image.
          virtualisation.useNixStoreImage = mkForce false;
          # We want to use at least the netboot's image Nix store!
          virtualisation.mountHostNixStore = mkForce false;
          # 2GiB because we are loading from memory the binaries.
          virtualisation.memorySize = 2048;
          # We do not need `diskImage` here.
          virtualisation.diskImage = null;
          # We do not want to direct boot the NixOS system generated by this expression.
          virtualisation.directBoot.enable = false;

          virtualisation.qemu.options = [
            # Network is the ONLY way to *boot*.
            # No disk, no CD.
            "-boot order=n,strict=true"
          ];

          # We do not want any networking in the guest, except for our TFTP stuff.
          virtualisation.vlans = mkDefault [];
          virtualisation.qemu.networkingOptions = [
            # Simulate a TFTP server, user.0 is already taken by the existing networking system.
            ''-netdev user,id=user.1,net=10.0.3.0/24,tftp-server-name="NixOS QEMU test built-in server",tftp=${ipxeBootDir},bootfile=netboot.ipxe,''${QEMU_NET_OPTS:+,$QEMU_NET_OPTS}''
            "-device virtio-net-pci,netdev=user.1"
          ];
        };
        testScript =
        ''
          machine.start()
          machine.wait_for_unit("multi-user.target")

          # For debugging purpose and sanity checks.
          print(machine.succeed("lsblk"))
          print(machine.succeed("mount"))

          machine.succeed("nix store verify --no-trust -r --option experimental-features nix-command /run/current-system")
          with subtest("Check whether the channel got installed correctly"):
              machine.succeed("nix-instantiate --dry-run '<nixpkgs>' -A hello")
              machine.succeed("nix-env --dry-run -iA nixos.procps")

          machine.shutdown()
        '';
      };
  uefiBinary = {
    x86_64-linux = "${pkgs.OVMF.fd}/FV/OVMF.fd";
    aarch64-linux = "${pkgs.OVMF.fd}/FV/QEMU_EFI.fd";
  }.${pkgs.stdenv.hostPlatform.system};
in {
    uefiCdrom = makeBootTest "uefi-cdrom" {
      cdrom = "${iso}/iso/${iso.isoName}";
      bios = uefiBinary;
    };

    uefiUsb = makeBootTest "uefi-usb" {
      usb = "${iso}/iso/${iso.isoName}";
      bios = uefiBinary;
    };

    directNetboot = makeTest {
      name = "directboot-netboot";
      nodes.machine = {
        imports = [ ../modules/installer/netboot/netboot-minimal.nix ];
      };
      testScript = "machine.fail('stat /dev/vda')";
    };

    uefiNetboot = makeNetbootTest "uefi" {
      virtualisation.useEFIBoot = true;
      # TODO: an ideal test would be to try netbooting through another machine with DHCP and proper configuration.
      # Disable romfile for iPXE in NIC, we want to use EDK2 network stack.
      # virtualisation.qemu.networkingOptions = [ "-global virtio-net-pci.romfile=" ];

      # Custom ROM is needed for EFI PXE boot. I failed to understand exactly why, because QEMU should still use iPXE for EFI.
      virtualisation.qemu.networkingOptions = [ "-global virtio-net-pci.romfile=${pkgs.ipxe}/ipxe.efirom" ];
    };
} // optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") {
    biosCdrom = makeBootTest "bios-cdrom" {
      cdrom = "${iso}/iso/${iso.isoName}";
    };

    biosUsb = makeBootTest "bios-usb" {
      usb = "${iso}/iso/${iso.isoName}";
    };

    biosNetboot = makeNetbootTest "bios" {};

    ubootExtlinux = let
      sdImage = "${sd}/sd-image/${sd.imageName}";
      mutableImage = "/tmp/linked-image.qcow2";

      machineConfig = pythonDict {
        bios = "${pkgs.ubootQemuX86}/u-boot.rom";
        qemuFlags = "-m 768 -machine type=pc,accel=tcg -drive file=${mutableImage},if=ide,format=qcow2";
      };
    in makeTest {
      name = "boot-uboot-extlinux";
      nodes = { };
      testScript = ''
        import os

        # Create a mutable linked image backed by the read-only SD image
        if os.system("qemu-img create -f qcow2 -F raw -b ${sdImage} ${mutableImage}") != 0:
            raise RuntimeError("Could not create mutable linked image")

        machine = create_machine(${machineConfig})
        machine.start()
        machine.wait_for_unit("multi-user.target")
        machine.succeed("nix store verify -r --no-trust --option experimental-features nix-command /run/current-system")
        machine.shutdown()
      '';
    };
}
