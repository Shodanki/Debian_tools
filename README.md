# NVIDIA Tesla Driver Installation Script

This installation script is designed for Debian-based Linux systems to install the NVIDIA Tesla 470 driver. It provides two installation options:

1. **Tesla Driver Only (Default)**
2. **Tesla Driver with NVENC Support**

## Installation Options

### 1. Tesla Driver Only (Default)
- **Description:**  
  Installs only the NVIDIA Tesla 470 driver.
- **When to Use:**  
  - When you require basic GPU functionality without any additional video encoding or decoding support.
  - For systems where hardware-accelerated video processing (NVENC/NVDEC) is not necessary.
- **Installed Package:**  
  - `nvidia-tesla-470-driver`

### 2. Tesla Driver with NVENC Support
- **Description:**  
  Installs the NVIDIA Tesla 470 driver along with additional packages that enable NVENC/NVDEC support.
- **When to Use:**  
  - When your workflow involves hardware-accelerated video encoding or decoding (e.g., live streaming, video processing, or multimedia applications).
  - If you need to leverage the CUDA Toolkit, NVIDIA utilities, and FFmpeg configured for NVIDIA support.
- **Installed Packages:**  
  - `nvidia-tesla-470-driver`
  - `nvidia-cuda-toolkit`
  - `nvidia-utils-470`
  - `ffmpeg`

## Identifying Which Driver Should Be Used

Consider the following criteria to determine the appropriate installation option:

- **Use the Tesla Driver Only if:**
  - Your system is used for standard GPU compute tasks without the need for advanced video processing.
  - You aim for a minimal installation with fewer dependencies.
  - Hardware-accelerated video encoding/decoding is not part of your workload.

- **Use the Tesla Driver with NVENC Support if:**
  - Your projects or applications require hardware acceleration for video encoding and decoding.
  - You are working with multimedia applications or streaming services where NVENC can improve performance.
  - You need the additional packages (CUDA Toolkit, NVIDIA utilities, FFmpeg) to support NVENC functionalities.

## NVIDIA GT710 Considerations

This script is also intended for systems using the NVIDIA GT710 graphics card. However, please note the following:

- **GT710 and NVENC:**  
  The NVIDIA GT710 is an entry-level GPU, and its support for NVENC (NVIDIA's hardware-accelerated video encoding) may be limited or unavailable.  
- **How to Verify NVENC Support:**  
  - **Check NVIDIA's Official Documentation:** Visit the [NVIDIA website](https://www.nvidia.com) and search for the GT710 specifications.
  - **Review Community Forums and Technical Resources:** Look for user experiences or technical articles discussing NVENC support on the GT710.
- **Installation Recommendation:**  
  If your GT710 does not support NVENC, or if you are unsure about its capabilities, it is recommended to use the **Tesla Driver Only (Default)** installation option.
## Making the Script Executable

Before running the script, ensure it is executable. Use the following command to set the appropriate permissions:

```bash
chmod +x install_nvidia_tesla.sh


## How to Use the Script

1. **Ensure Root Privileges:**
   - The script must be run as the root user or with `sudo` to perform system modifications.
   

2. **Run the Script:**
   - Execute the script with:
     ```bash
     sudo ./install_nvidia_tesla.sh
     ```

3. **Choose an Installation Option:**
   - When prompted, enter:
     - `1` for Tesla Driver Only (default), or
     - `2` for Tesla Driver with NVENC Support

4. **System Reboot:**
   - After installation, the script will automatically reboot the system to apply the changes.

## Prerequisites

- A Debian-based Linux distribution.
- Internet connectivity to download necessary packages.
- Sufficient permissions to execute system-level commands (e.g., `apt` commands).

## Additional Notes

- The script begins by removing any existing NVIDIA drivers and disabling the Nouveau driver to prevent conflicts.
- It is advisable to review the script to ensure it meets your system requirements before execution.
- Use this script at your own risk; ensure you have backups or recovery options in case any issues arise.

---

*This script is provided "as is" without warranty of any kind. Use it responsibly and adapt it to your environment as needed.*
