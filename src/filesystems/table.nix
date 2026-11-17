# What each filesystem type needs: the kernel module that provides it (the
# initrd copies it when the filesystem is mounted at boot), the userspace
# tools (mkfs, fsck and the mount.<type> helper that mount looks for in
# /run/current-system/sw/bin), and whether it needs the network, so it is
# mounted once the network is up instead of during activation.
pkgs: {
  ext2 = {
    module = "ext4";
    packages = [ pkgs.e2fsprogs ];
  };
  ext3 = {
    module = "ext4";
    packages = [ pkgs.e2fsprogs ];
  };
  ext4 = {
    module = "ext4";
    packages = [ pkgs.e2fsprogs ];
  };
  btrfs = {
    module = "btrfs";
    packages = [ pkgs.btrfs-progs ];
  };
  xfs = {
    module = "xfs";
    packages = [ pkgs.xfsprogs ];
  };
  f2fs = {
    module = "f2fs";
    packages = [ pkgs.f2fs-tools ];
  };
  vfat = {
    module = "vfat";
    packages = [ pkgs.dosfstools ];
  };
  msdos = {
    module = "msdos";
    packages = [ pkgs.dosfstools ];
  };
  exfat = {
    module = "exfat";
    packages = [ pkgs.exfatprogs ];
  };
  # The kernel's NTFS driver; ntfs-3g still brings ntfsfix and mkntfs.
  ntfs3 = {
    module = "ntfs3";
    packages = [ pkgs.ntfs3g ];
  };
  ntfs = {
    module = "ntfs3";
    packages = [ pkgs.ntfs3g ];
  };
  # The FUSE NTFS driver, for when ntfs3 refuses a volume.
  ntfs-3g = {
    module = "fuse";
    packages = [ pkgs.ntfs3g ];
  };
  iso9660 = {
    module = "isofs";
    packages = [ ];
  };
  udf = {
    module = "udf";
    packages = [ ];
  };
  squashfs = {
    module = "squashfs";
    packages = [ pkgs.squashfsTools ];
  };
  nfs = {
    module = "nfs";
    packages = [ pkgs.nfs-utils ];
    network = true;
  };
  nfs4 = {
    module = "nfsv4";
    packages = [ pkgs.nfs-utils ];
    network = true;
  };
  cifs = {
    module = "cifs";
    packages = [ pkgs.cifs-utils ];
    network = true;
  };
  smb3 = {
    module = "cifs";
    packages = [ pkgs.cifs-utils ];
    network = true;
  };
  "fuse.sshfs" = {
    module = "fuse";
    packages = [ pkgs.sshfs ];
    network = true;
  };
  sshfs = {
    module = "fuse";
    packages = [ pkgs.sshfs ];
    network = true;
  };
}
