# The Mahout's Creed
## Philosophy: Security through Minimalism (O(1) Silence)
Ankusha is engineered as a **Native HPC Manifestation**. In Critical Infrastructure environments, the most significant vulnerability is often the "Security Tooling" itself. By eliminating the need for a web server, a database, or third-party interpreters (Python/Node.js), Ankusha reduces the **Supply Chain Attack Surface** to absolute zero.
We follow the principle of **"Living off the Land"**: if the binary isn't already part of the LINUX core or the Slurm environment, Ankusha does not use it.
## Threat Model & Mitigation Strategy
| Threat Vector | Ankusha Defensive Control |
|---|---|
| **Privilege Escalation** | **Zero-Sudo Architecture.** Ankusha is a user-space Mahout. It never requests or requires root access. It operates strictly within the permissions of the current user, ensuring it cannot be used as a vector for privilege escalation. |
| **Supply Chain Compromise** | **Dependency-Free Execution.** By eschewing pip, npm, and external modules, Ankusha is immune to "Dependency Confusion" or "Typosquatting" attacks. The code is 100% auditable Bash. |
| **Remote Code Execution** | **No Network Footprint.** Ankusha opens zero sockets, starts no listeners, and has no "phone home" telemetry. It is fundamentally invisible to network-based scanners (Nmap/Zmap) and remote exploit attempts. |
| **Lateral Movement** | **Local Scoping.** Ankusha does not store or transmit credentials. It leverages existing Slurm environment tokens for data fetching, preventing the storage of "secrets" in memory or on disk. |
| **Data Integrity** | **Read-Only Manifestation.** Ankusha treats system data (via /proc and sinfo) as read-only. It does not modify system states, ensuring no interference with the operational integrity of the mammoth (the HPC). |
## Secure Operation Practices
### 1. User-Space Resilience
Ankusha is designed for high-security, air-gapped environments. It fetches metrics directly from standard Slurm binaries and the /proc filesystem. Because it runs as a standard process, it is subject to the same **SELinux** or **AppArmor** profiles as any other user job, ensuring a "Sandbox-by-Default" posture.
### 2. Environment Sanitization
 * **Variable Isolation:** All script logic uses local-scoping to prevent sensitive environment variables from leaking into the global shell.
 * **Input Neutralization:** Ankusha is a non-interactive dashboard. It does not accept external flags or user-defined strings during execution, neutralizing the risk of **Shell Injection**.
 * **Zero Persistance:** No job metadata or cluster telemetry is written to persistent logs. The "Manifestation" exists only in volatile memory while the dashboard is active.
## Reporting a Vulnerability
As a "User-space Mahout," I prioritize the logic of control. If you identify an edge case where the tool could cause resource exhaustion or bypass Slurm's standard user-level restrictions, please report it via GitHub Issues. Logic-based bypasses are treated with the highest priority.
