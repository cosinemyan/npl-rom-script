#!/bin/bash
# TWRP Packer - Create TWRP flashable zip

create_twrp_zip() {
  local firmware_dir="$1"
  local output_dir="$2"
  local device_name="$3"
  
  log_info "Creating TWRP flashable package..."
  
  mkdir -p "$output_dir"
  
  local zip_dir="$output_dir/twrp_package"
  mkdir -p "$zip_dir/META-INF/com/google/android"
  
  log_info "Creating updater-script..."
  
  cat > "$zip_dir/META-INF/com/google/android/updater-script" << 'EOF'
# Mount partitions
mount("ext4", "EMMC", "/dev/block/by-name/super", "/system", "");
mount("ext4", "EMMC", "/dev/block/by-name/super", "/vendor", "");
mount("ext4", "EMMC", "/dev/block/by-name/super", "/product", "");

# Package install
package_extract_dir("system", "/system");
package_extract_dir("vendor", "/vendor");
package_extract_dir("product", "/product");

# Set permissions
set_perm_recursive(0, 0, 0755, 0644, "/system");
set_perm_recursive(0, 2000, 0755, 0755, "/system/bin");

# Unmount
unmount("/system");
unmount("/vendor");
unmount("/product");
EOF
  
  log_info "Copying partitions..."
  
  if [[ -d "$firmware_dir/system" ]]; then
    cp -r "$firmware_dir/system" "$zip_dir/"
  fi
  
  if [[ -d "$firmware_dir/vendor" ]]; then
    cp -r "$firmware_dir/vendor" "$zip_dir/"
  fi
  
  if [[ -d "$firmware_dir/product" ]]; then
    cp -r "$firmware_dir/product" "$zip_dir/"
  fi
  
  local output_zip="$output_dir/${device_name}_twrp.zip"
  
  log_info "Creating zip: $output_zip"
  
  cd "$zip_dir"
  zip -r "$output_zip" . > /dev/null
  cd - > /dev/null
  
  rm -rf "$zip_dir"
  
  log_info "TWRP package created: $output_zip"
  echo "$output_zip"
}