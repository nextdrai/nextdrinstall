# NextDR Software Installation Script

This script facilitates the installation and management of the entire NextDR software suite. For all operations, it supports both **interactive mode** and **express mode** for flexibility and ease of use.

To download run file, run command:

sudo curl -L -o ndr_installer.run https://github.com/nextdrai/nextdrinstall/raw/main/deploy/ndr_installer.run

To optionally download tar file of install package suite, run command:

sudo curl -L -o ndr_installer.run https://github.com/nextdrai/nextdrinstall/raw/main/deploy/ndr_installer.tar.gz

---

## Scripts

- **ndrInstall.sh**  
  Orchestrates the installation and configuration of the NextDR software suite, including prerequisites, Supabase, service, and UI components. Supports both interactive and express (automated) modes.

- **ndrAdmin.sh**  
  Allows for starting and stopping the currently installed NextDR modules.
