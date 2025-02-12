echo "?? Installing benchmark tools (glxgears, vulkaninfo)..."
apt install -y mesa-utils vulkan-tools

echo "?? Running OpenGL test..."
glxgears

echo "?? Running Vulkan test..."
vulkaninfo | grep "GPU id"
