#!/bin/bash


## DO NOT MODIFY VARIABLES BELOW THIS LINE ##
tmpdir=""

help(){
  echo "Usage: Makeipsw.sh <ota.zip> <donor.ipsw> <output.ipsw> [keys-zip.zip]"
}

cleanup(){
  echo "Performing cleanup"

  echo "Deleting '${tmpdir}'"
  rm -rf ${tmpdir} 2>/dev/null || sudo rm -rf ${tmpdir}
}

getTicket(){
  target=$1
  buildmanifest=$2
  output=$3
  if [ "x${target}" == "x" ] || [ "x${buildmanifest}" == "x" ] || [ "x${output}" == "x" ]; then
    echo "Arguments error in getTicket"
    exit 1
  fi
  echo "Getting OTA ticket for target '${target}'"
  tsschecker -d "${target}" -m "${buildmanifest}" -s"${output}"
}

patchasr(){
  asrpath=$1
  if [ "x${asrpath}" == "x" ]; then
    echo "Arguments error in patchasr"
    exit 1
  fi

  strloc=$(binrider --string "Image failed signature verification." "${asrpath}" | grep "Found 'Image failed signature verification.' at" | rev | cut -d ' ' -f1 | rev)
  echo "strloc=${strloc}"
  strref=$(binrider --xref "${strloc}" "${asrpath}" | grep "Found xrefs at" | rev | cut -d ' ' -f1 | rev)
  echo "strref=${strref}"
  bof=$(binrider --bof "${strref}" "${asrpath}" | grep "Found beginning of function at" | rev | cut -d ' ' -f1 | rev)
  echo "bof=${bof}"
  cref=$(binrider --cref "${bof}" "${asrpath}" | grep "Found call refs at" | rev | cut -d ' ' -f1 | rev)
  echo "cref=${cref}"
  paddr=""
  for i in $(seq 0 4 0x30); do
    tgtdec=$((${cref} - ${i}))
    tgt=$(printf '0x%x\n' ${tgtdec})
    failstr="No refs found to ${tgt}"
    bref=$(binrider --bref "${tgt}" "${asrpath}")
    if echo "${bref}" | grep "${failstr}"; then
      continue
    fi
    paddr=$(echo "${bref}" | grep "Found branch refs at" | head -n1 | rev | cut -d ' ' -f1 | rev)
    break
  done
  if [ "x${paddr}" == "x" ]; then
    echo "Patchfinder failed to find patch addr"
    exit 3
  fi
  echo "Found patch address at '${paddr}'"
  fof=$(binrider --fof "${paddr}" "${asrpath}" | grep "Found fileoffset at" | rev | cut -d ' ' -f1 | rev)
  echo "fof=${fof}"

  echo "Patching file"
  echo -en "\x1F\x20\x03\xD5" | sudo dd of="${asrpath}" bs=1 seek=$((${fof})) conv=notrunc count=4

  echo "Resigning file"
  sudo ldid -s "${asrpath}"
}

makerootfs(){
  otadir="$1"
  outramdisk="$2"
  wrkdir="$3"
  if [ "x${otadir}" == "x" ] || [ "x${outramdisk}" == "x" ] || [ "x${wrkdir}" == "x" ]; then
    echo "Arguments error in makerootfs"
    exit 1
  fi
  echo "otadir=${otadir}"
  echo "outramdisk=${outramdisk}"
  echo "wrkdir=${wrkdir}"


  for i in $(seq 1 10); do
    echo ""
  done
  echo "Creating a rootfs is only something the most privileged of us can do!"
  echo "You may be asked for your password, please type it in to proof you're a privileged one!"
  sudo echo "Yes, i am privileged" 
  if [ $? -ne 0 ]; then 
    echo "Sorry, you have no privileges here!"
    exit 99
  fi

  # Ensure that prepare_payload, firmlinks_payload, and links.txt are indeed empty
  if [[ -e "${otadir}/AssetData/payloadv2/prepare_payload" ]] && [[ $(yaa list -i "${otadir}/AssetData/payloadv2/prepare_payload") ]]; then
    echo "Image contains a prepare payload, this is currently not supported."
    exit 1
  fi
  if [[ -e "${otadir}/AssetData/payloadv2/data_payload" ]] && [[ $(yaa list -i "${otadir}/AssetData/payloadv2/data_payload") ]]; then
    echo "Image contains a data payload (nonstandard format), this is currently not supported."
    exit 1
  fi
  if [[ -e "${otadir}/AssetData/payloadv2/firmlinks_payload" ]] && [[ $(yaa list -i "${otadir}/AssetData/payloadv2/firmlinks_payload") ]]; then
    echo "Image contains a firmlinks payload, this is currently not supported."
    exit 1
  fi
  if [[ -e "${otadir}/AssetData/payloadv2/links.txt" ]] && [[ -s "${otadir}/AssetData/payloadv2/links.txt" ]]; then
    echo "Image contains links, these are currently not handled."
    exit 1
  fi

  rootfsdir="${wrkdir}/rootfs"
  mkdir -p "${rootfsdir}"

	for i in $(awk -F':' '{print $1}' "${otadir}/AssetData/payloadv2/payload_chunks.txt"); do 
		nn=$(printf "%03d" "$i")
		echo "Extracting chunk ${nn}..."
		sudo yaa extract -v -d "${rootfsdir}" -i "${otadir}/AssetData/payloadv2/payload.${nn}"
	done
  
  # copy UNMODIFIED usr/standalone/update/ramdisk/arm64SURamDisk.dmg to rootfs
	sudo cp -a "${otadir}/AssetData/payload/replace/usr/standalone/update/ramdisk/arm64SURamDisk.dmg" "${rootfsdir}/usr/standalone/update/ramdisk/"
	sudo chown root:wheel "${rootfsdir}/usr/standalone/update/ramdisk/arm64SURamDisk.dmg"
	sudo chmod 644 "${rootfsdir}/usr/standalone/update/ramdisk/arm64SURamDisk.dmg"
	sudo /usr/bin/xattr -c "${rootfsdir}/usr/standalone/update/ramdisk/arm64SURamDisk.dmg"


  BUILDTRAIN="$(/usr/bin/plutil -extract "BuildIdentities".0."Info"."BuildTrain" raw -o - "${otadir}/AssetData/boot/BuildManifest.plist")"
  BUILDNUMBER="$(/usr/bin/plutil -extract "BuildIdentities".0."Info"."BuildNumber" raw -o - "${otadir}/AssetData/boot/BuildManifest.plist")"
  APTARGETTYPE="$(/usr/bin/plutil -extract "BuildIdentities".0."Ap,TargetType" raw -o - "${otadir}/AssetData/boot/BuildManifest.plist")"
  VOLNAME="${BUILDTRAIN}${BUILDNUMBER}.${APTARGETTYPE}OS"
  IMGSIZE_MB=$(($(sudo du -A -s -m "${rootfsdir}" | awk '{ print $1 }')+100))
  IMGNAME="$(/usr/bin/plutil -extract "BuildIdentities".0."Manifest"."OS"."Info"."Path" raw -o - "${otadir}/AssetData/boot/BuildManifest.plist")"
  MTREENAME=$(/usr/bin/plutil -extract "BuildIdentities".0."Manifest"."Ap,SystemVolumeCanonicalMetadata"."Info"."Path" raw -o - "${otadir}/AssetData/boot/BuildManifest.plist")
  # create DMG 100MB larger 

  echo "Creating a dmg with ${IMGSIZE_MB} MB free"
  IMGFILEINFO="$(hdiutil create -megabytes "${IMGSIZE_MB}" -layout NONE -attach -volname RESTORE -fs 'exFAT' "${wrkdir}/os.udrw.dmg")"
  IMGNODE="$(echo "$IMGFILEINFO" | head -n1 | awk '{print $1}')"
  diskutil unmountDisk "${IMGNODE}"
  diskutil partitionDisk -noEFI ${IMGNODE} 1 "GPT" "Free Space" "${VOLNAME}" 100
  APFSOUTPUT="$(diskutil apfs createContainer "${IMGNODE}")"
  APFSNODE="$(echo "$APFSOUTPUT" | grep 'Disk from APFS operation' | awk '{print $5}')"
  APFSVOLOUTPUT="$(diskutil apfs addVolume "${APFSNODE}" "Case-sensitive APFS" "${VOLNAME}" -role S)"
  APFSVOLNODE="$(echo "$APFSVOLOUTPUT" | grep 'Disk from APFS operation' | awk '{print $5}')"

  sudo diskutil enableOwnership ${APFSVOLNODE}

  if [[ $(diskutil info "${APFSVOLNODE}" | grep 'Mounted' | grep 'Yes') ]]; then
    MOUNTPOINT="$(diskutil info "${APFSVOLNODE}" | grep 'Mount Point' | sed 's/[[:space:]]*Mount\ Point:[[:space:]]*//')"
  else
    echo "Disk image is not mounted or could not determine mountpoint."
    exit 1
  fi

  # copy files from tmpdir to image
  echo "Copying to ${APFSVOLNODE} aka ${MOUNTPOINT}"
  sudo ditto "${rootfsdir}" "${MOUNTPOINT}"

  sudo rm -rf "${MOUNTPOINT}/.fseventsd"

  # fix up the extracted files
  sudo yaa check-and-fix -d "${MOUNTPOINT}" -i "${otadir}/AssetData/payloadv2/fixup.manifest"

  # extract the mtree into a text file
  img4tool -e "${otadir}/AssetData/boot/${MTREENAME}" -o "${wrkdir}/mtree.aa"
  (
    cd "${wrkdir}"
    yaa extract -i "${wrkdir}/mtree.aa"
  )

  echo "Comparing image against mtree. Certain properties are expected not to match. All files and file sizes should match."
  # the excluded lines are based on running this command on a real ipsw
  echo sudo mtree -p "${MOUNTPOINT}" -f "${wrkdir}/mtree.txt" -q | grep -v 'inode expected' | grep -v 'changed' | grep -v 'xattrsdigest expected'
  sudo mtree -p "${MOUNTPOINT}" -f "${wrkdir}/mtree.txt" -q | grep -v 'inode expected' | grep -v 'changed' | grep -v 'xattrsdigest expected'

  #eject rootfs
  hdiutil detach "${MOUNTPOINT}"

  # convert image to ULFO
  echo hdiutil convert -format ULFO -o "${outramdisk}" "${wrkdir}/os.udrw.dmg"
  hdiutil convert -format ULFO -o "${outramdisk}" "${wrkdir}/os.udrw.dmg"
  # this embeds checksums in the image which are reqiured for asr
  asr imagescan --source "${outramdisk}"
  echo "Done creating rootfs"
}

##### MAIN ######
main(){
  otaPath=$1
  donorPath=$2
  outputPath=$3
  keysPath=$4

  if [ "x${otaPath}" == "x" ] || [ "x${donorPath}" == "x" ] || [ "x${outputPath}" == "x" ]; then
    help
    exit 1
  fi

  echo "otaPath=${otaPath}"
  echo "donorPath=${donorPath}"
  echo "outputPath=${outputPath}"

  tmpdir=$(mktemp -d /tmp/homepodtmpXXXXXXXXXX)
  echo "tmpdir=${tmpdir}"
  ipswdir=${tmpdir}/ipsw
  otadir=${tmpdir}/ota
  ra1nsn0wdir=${tmpdir}/ra1nsn0w
  rootfswrkdir=${tmpdir}/rootfswrkdir
  mkdir -p ${ipswdir}
  mkdir -p ${otadir}
  mkdir -p ${ra1nsn0wdir}
  mkdir -p ${rootfswrkdir}

  echo "extracting ota to '${otadir}'"
  unzip ${otaPath} -d ${otadir}

  makerootfs ${otadir} "${ipswdir}/myrootfs.dmg" ${rootfswrkdir}

  mv "${otadir}/AssetData/boot/"* "${ipswdir}/"
  rm -rf "${otadir}/AssetData/boot/"

  targetProduct=$(plutil -extract "BuildIdentities".0."Ap,ProductType" raw "${ipswdir}/BuildManifest.plist")
  targetHardware=$(plutil -extract "BuildIdentities".0."Ap,Target" raw "${ipswdir}/BuildManifest.plist")
  echo "Found target: '${targetProduct}' '${targetHardware}"
  getTicket ${targetProduct} "${ipswdir}/BuildManifest.plist" "${tmpdir}/ticket.shsh2"

  ra1nsn0w -t "${tmpdir}/ticket.shsh2" \
    --ipatch-no-force-dfu \
    --kpatch-always-get-task-allow \
    --kpatch-codesignature \
    -b "rd=md0 -v serial=3 nand-enable-reformat=1 -restore" \
    --dry-run "${targetProduct}":"${targetHardware}":1 \
    --dry-out "${ra1nsn0wdir}" \
    --ota "${otaPath}" \
    $([[ "$keysPath" ]] && echo "--keys-zip ${keysPath}")

  iBSSPathPart=$(plutil -extract "BuildIdentities".0.Manifest.iBSS.Info.Path raw "${ipswdir}/BuildManifest.plist")
  iBECPathPart=$(plutil -extract "BuildIdentities".0.Manifest.iBEC.Info.Path raw "${ipswdir}/BuildManifest.plist")

  echo "Deploying patched bootloaders"

  rm "${ipswdir}/${iBSSPathPart}"
  img4tool -e -p "${ipswdir}/${iBSSPathPart}" "${ra1nsn0wdir}/component1.bin"

  rm "${ipswdir}/${iBECPathPart}"
  img4tool -e -p "${ipswdir}/${iBECPathPart}" "${ra1nsn0wdir}/component2.bin"

  echo "Deploying patched kernel"

  ra1nsn0wLastComponent=$(ls -l ${ra1nsn0wdir} | tail -n1 | rev | cut -d ' ' -f1 | rev)
  img4tool -e -p "${ipswdir}/restorekernel.im4p" "${ra1nsn0wdir}/${ra1nsn0wLastComponent}"

  plutil -replace "BuildIdentities".0.Manifest.RestoreKernelCache.Info.Path -string restorekernel.im4p -o "${ipswdir}/BuildManifest_new.plist" "${ipswdir}/BuildManifest.plist"
  mv -f "${ipswdir}/BuildManifest_new.plist" "${ipswdir}/BuildManifest.plist"

  echo "Extract donor BuildManifest.plist"
  unzip ${donorPath} -d ${tmpdir} BuildManifest.plist

  cntIdentites=$(plutil -extract "BuildIdentities" raw ${tmpdir}/BuildManifest.plist)
  foundident="-1"
  echo "Donor has ${cntIdentites} buildidentities"
  for i in $(seq 0 $((${cntIdentites}-1))); do
    echo "checking ident ${i}..."
    variant=$(plutil -extract "BuildIdentities.${i}.Info.Variant" raw ${tmpdir}/BuildManifest.plist)
    if echo ${variant} | grep "Customer Erase Install (IPSW)"; then
      foundident=${i}
      break
    fi
  done

  if [[ $foundident  -eq "-1" ]]; then
    echo "Failed to find target buildidentity"
    exit 2
  fi
  echo "Found target buildidentity (${foundident}), getting ramdisk"
  restoreramdisk=$(plutil -extract "BuildIdentities.${foundident}.Manifest.RestoreRamDisk.Info.Path" raw ${tmpdir}/BuildManifest.plist)

  echo "Extracting ramdisk '${restoreramdisk}'"
  unzip ${donorPath} -d ${tmpdir} ${restoreramdisk}
  img4tool -e -o "${tmpdir}/rdsk.dmg" "${tmpdir}/${restoreramdisk}"

  echo "Mounting ramdisk"
  mntpoint=$(hdiutil attach "${tmpdir}/rdsk.dmg" | tail -n1 | cut -d $'\t' -f3)
  echo "Ramdisk mounted at '${mntpoint}'"

  if [[ ! -f "${mntpoint}/usr/local/bin/restored_external" ]]; then
    echo "Ramdisk does not contain a restored_external binary. Either the ipsw is corrupt/incorrect, or this script has a bug."
    exit 3
  fi

  echo "Patching asr"
  patchasr "${mntpoint}/usr/sbin/asr"

  echo "Unmounting ramdisk"
  hdiutil detach "${mntpoint}"

  echo "Patching RestoreRamDisk path in BuildManifest"
  plutil -replace "BuildIdentities".0.Manifest.RestoreRamDisk.Info.Path -string myramdisk.dmg -o "${ipswdir}/BuildManifest_new.plist" "${ipswdir}/BuildManifest.plist"
  mv -f "${ipswdir}/BuildManifest_new.plist" "${ipswdir}/BuildManifest.plist"

  echo "Packing ramdisk to im4p file"
  img4tool -c "${ipswdir}/myramdisk.dmg" -t rdsk "${tmpdir}/rdsk.dmg"

  echo "Patching OS path in BuildManifest"
  plutil -replace "BuildIdentities".0.Manifest.OS.Info.Path -string myrootfs.dmg -o "${ipswdir}/BuildManifest_new.plist" "${ipswdir}/BuildManifest.plist"
  mv -f "${ipswdir}/BuildManifest_new.plist" "${ipswdir}/BuildManifest.plist"

  echo "Setting Restore behavior in BuildManifest"
  plutil -replace "BuildIdentities".0.Info.RestoreBehavior -string "Erase" -o "${ipswdir}/BuildManifest_new.plist" "${ipswdir}/BuildManifest.plist"
  mv -f "${ipswdir}/BuildManifest_new.plist" "${ipswdir}/BuildManifest.plist"

  echo "Setting Variant in BuildManifest to match Erase Install"
  plutil -replace "BuildIdentities".0.Info.Variant -string "Customer Erase Install (IPSW)" -o "${ipswdir}/BuildManifest_new.plist" "${ipswdir}/BuildManifest.plist"
  mv -f "${ipswdir}/BuildManifest_new.plist" "${ipswdir}/BuildManifest.plist"

  echo "Setting RecoveryVariant in BuildManifest to match Recovery Customer Install"
  plutil -replace "BuildIdentities".0.Info.RecoveryVariant -string "Recovery Customer Install" -o "${ipswdir}/BuildManifest_new.plist" "${ipswdir}/BuildManifest.plist"
  mv -f "${ipswdir}/BuildManifest_new.plist" "${ipswdir}/BuildManifest.plist"

  echo "Compressing IPSW"

  (
    cd "${ipswdir}"
    zip -r "${tmpdir}/mycfw.ipsw" .
  )
  mv "${tmpdir}/mycfw.ipsw" "${outputPath}"

  cleanup
  echo "Done!!"
}

main $@