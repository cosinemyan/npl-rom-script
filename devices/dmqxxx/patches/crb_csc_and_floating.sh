#!/bin/bash
# CRB Kitchen - S23 CSC features + Floating feature
# Source: CRB Kitchen cscfeature() S23 branch and modvendor() floating feature

crb_csc_and_floating() {
  local mp="$1"  # partition mount point being patched

  # ── CSC Features (optics/configs/carriers tree) ───────────────────────────
  # On S23 the CSC XML lives in the optics partition which maps to product
  # Try both common locations
  local csc_dirs=(
    "$mp/optics/configs/carriers"
    "$mp/configs/carriers"
    "$mp"
  )

  local csc_applied=false
  for csc_dir in "${csc_dirs[@]}"; do
    if [[ ! -d "$csc_dir" ]]; then continue; fi
    local csc_files
    mapfile -t csc_files < <(find "$csc_dir" -type f -name "cscfeature.xml" 2>/dev/null)
    if [[ ${#csc_files[@]} -eq 0 ]]; then continue; fi

    for csc_file in "${csc_files[@]}"; do
      log_info "[CRB] Patching CSC: $csc_file"

      # Remove existing entries to avoid duplicates
      sed -i '/CscFeature_SystemUI_ConfigOverrideDataIcon\|CscFeature_Wifi_SupportAdvancedMenu\|CscFeature_SmartManager_ConfigDashboard\|CscFeature_SmartManager_DisableAntiMalware\|CscFeature_Calendar_SetColorOfDays\|CscFeature_Camera_ShutterSoundMenu\|CscFeature_Camera_EnableCameraDuringCall\|CscFeature_Camera_EnableSmsNotiPopup\|CscFeature_Common_ConfigSvcProviderForUnknownNumber\|CscFeature_Setting_SupportRealTimeNetworkSpeed\|CscFeature_VoiceCall_ConfigRecording\|CscFeature_SystemUI_SupportRecentAppProtection\|CscFeature_Knox_SupportKnoxGuard\|CscFeature_RIL_SupportEsim\|CscFeature_SmartManager_ConfigSubFeatures\|CscFeature_Web_SetHomepageURL\|CscFeature_Common_EnhanceImageQuality\|CscFeature_Message_SupportAntiPhishing/d' "$csc_file" || true

      # Inject features after <FeatureSet> opening tag
      sed -i '/<FeatureSet>/a\    <CscFeature_SystemUI_ConfigOverrideDataIcon>LTE<\/CscFeature_SystemUI_ConfigOverrideDataIcon>\n    <CscFeature_Wifi_SupportAdvancedMenu>TRUE<\/CscFeature_Wifi_SupportAdvancedMenu>\n    <CscFeature_SmartManager_ConfigDashboard>dual_dashboard<\/CscFeature_SmartManager_ConfigDashboard>\n    <CscFeature_SmartManager_DisableAntiMalware>TRUE<\/CscFeature_SmartManager_DisableAntiMalware>\n    <CscFeature_Calendar_SetColorOfDays>XXXXXBR<\/CscFeature_Calendar_SetColorOfDays>\n    <CscFeature_Camera_ShutterSoundMenu>TRUE<\/CscFeature_Camera_ShutterSoundMenu>\n    <CscFeature_Camera_EnableCameraDuringCall>TRUE<\/CscFeature_Camera_EnableCameraDuringCall>\n    <CscFeature_Camera_EnableSmsNotiPopup>TRUE<\/CscFeature_Camera_EnableSmsNotiPopup>\n    <CscFeature_Setting_SupportRealTimeNetworkSpeed>TRUE<\/CscFeature_Setting_SupportRealTimeNetworkSpeed>\n    <CscFeature_VoiceCall_ConfigRecording>RecordingAllowed,RecordingAllowedByMenu<\/CscFeature_VoiceCall_ConfigRecording>\n    <CscFeature_SystemUI_SupportRecentAppProtection>TRUE<\/CscFeature_SystemUI_SupportRecentAppProtection>\n    <CscFeature_Knox_SupportKnoxGuard>FALSE<\/CscFeature_Knox_SupportKnoxGuard>\n    <CscFeature_RIL_SupportEsim>TRUE<\/CscFeature_RIL_SupportEsim>\n    <CscFeature_SmartManager_ConfigSubFeatures>applock<\/CscFeature_SmartManager_ConfigSubFeatures>\n    <CscFeature_Web_SetHomepageURL>https:\/\/www.google.com\/<\/CscFeature_Web_SetHomepageURL>\n    <CscFeature_Common_EnhanceImageQuality>TRUE<\/CscFeature_Common_EnhanceImageQuality>\n    <CscFeature_Message_SupportAntiPhishing>TRUE<\/CscFeature_Message_SupportAntiPhishing>' "$csc_file" || true
    done
    csc_applied=true
  done

  if [[ "$csc_applied" == "true" ]]; then
    log_info "[CRB] CSC features applied"
  else
    log_info "[CRB] No cscfeature.xml found under $mp — skipping CSC patch"
  fi

  # ── Floating Feature: Battery Health menu (S23 specific) ──────────────────
  local float_files=(
    "$mp/system/etc/floating_feature.xml"
    "$mp/etc/floating_feature.xml"
  )
  for float_file in "${float_files[@]}"; do
    if [[ -f "$float_file" ]]; then
      if ! grep -q "SEC_FLOATING_FEATURE_BATTERY_SUPPORT_BSOH_SETTINGS" "$float_file"; then
        sed -i '/<\/SecFloatingFeatureSet>/i\    <SEC_FLOATING_FEATURE_BATTERY_SUPPORT_BSOH_SETTINGS>TRUE<\/SEC_FLOATING_FEATURE_BATTERY_SUPPORT_BSOH_SETTINGS>' "$float_file" || true
        log_info "[CRB] Floating feature BSOH added: $float_file"
      fi
    fi
  done
}
