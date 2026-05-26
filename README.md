# File Backup and Restore
## What is it?
This is a collection of scripts for quickly backing up and restoring user files on both macOS and Windows systems. The Windows client uses `robocopy` and the macOS version uses `rsync`.

The benefit is that `robocopy` uses multithreading, unlike file explorer, or the `Copy-Item` cmdlet in PowerShell.

`rsync` is a fast file transfer tool for UNIX based systems (like macOS), and is very efficient in copying files from one location to another.

## How does it work?
The process both scripts run through is as follows:
1. The script looks through all drives on the system, and allows the user to choose which drive to back up to
2. It presents a menu with options for the user to configure the backup process
4. It looks up how many threads are on the system (to use in `robocopy`)
6. Upon user selection it begins the backup process after configuration has been completed
8. It will let the user know when the operation is complete, if there were any errors, and that they can eject the USB drive

## Why should I care?
If you are trying to back up user data that is hundreds of gigabytes in size, this will save a considerable amount of time. For reference: a ~100G file transfer using Windows File Explorer on a 4 core 8 thread machine takes about 1 hour 30 minutes, whereas the same transfer using `robocopy` and allocating all 8 threads takes about 15 minutes.

Obviously your biggest limitation in this regard will be the I/O buffer, but regardless there is still a major performance increase.

### Legal Stuff
Copyright (c) 2026 Arthur Taft
