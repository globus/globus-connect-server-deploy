<br />
<p align="center">
  <h3 align="center">GCS Ansible Playbook</h3>
</p>

<details open="open">
  <summary>Table of Contents</summary>
  <ol>
    <li><a href="#about-the-project">About The Project</a></li>
    <li>
      <a href="#how-do-i-use-this-for-installations">
        How do I use this for installations?
      </a>
    </li>
    <li><a href="#license">License</a></li>
    <li><a href="#contact">Contact</a></li>
  </ol>
</details>

## About The Project
This project provides tools that support the deployment of [Globus Connect Server](https://www.globus.org/globus-connect) using Ansible. It serves as a starting point for endpoint administrators interested in automated deployment for production or testing purposes. Ansible knowledge is assumed since the examples will most likely need to be adapted to fit your environment.

**GCSv5 has its own officially-supported [installation procedures](https://docs.globus.org/globus-connect-server-v5-installation-guide/)**. This installer does not replace that process and it is likely that updates to this installer repo will lag feature releases of GCSv5.

## How do I use this for installations?

1. Git clone the repo to your installation node
    ```shell
    $ git clone https://github.com/globus/globus-connect-server-deploy.git
    ```
2. Install Python3 on the target system.
3. Setup passwordless SSH to the target system to an account that has sudo access.
4. Run `ansible-playbook --inventory=<target_system>, --user=<remote_user> playbook.yml`.

## License
All work is copyright the University of Chicago. All rights reserved.

## Contact
Please direct all support questions to `support@globus.org`.
