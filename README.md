# ROM Builder - Basic Run Steps

1. Open terminal in project root:
   ```bash
   cd /home/cosine/projects/android/rom-builder
   ```

2. Setup tools first:
   ```bash
   chmod +x tools/setup.sh
   ./tools/setup.sh
   ```

3. Put firmware file in one of these locations:
   - `firmware/dm1q/` or `firmware/dm2q/` or `firmware/dm3q/`
   - or `firmware/` (filename must contain device name like `dm1q`)

4. Run easy mode:
   ```bash
   chmod +x tools/easy_build.sh
   ./tools/easy_build.sh
   ```

5. Or run direct CLI mode:
   ```bash
   chmod +x cli/main.sh
   ./cli/main.sh build --device dm1q --profile all --input firmware/dm1q/your_firmware.zip --output odin
   ```
