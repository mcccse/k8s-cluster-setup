# Create talos snapshot for hetzner

Commands to generate a talos snapshot that can be used at Hetzner
Surf to  <https://factory.talos.dev/>
and review other options that can be enabled

```bash
HCLOUD_LOCATION="hel1"
TALOS_VERSION="v1.12.4"
SCHEMATIC_ID=$(curl -sX POST \
  https://factory.talos.dev/schematics \
  -H "Content-Type: application/yaml" \
  --data-binary '
customization:
  systemExtensions:
    officialExtensions:
      - siderolabs/qemu-guest-agent
' | jq -r '.id')
```

```bash
hcloud server create \
  --name talos-image-builder \
  --type cx23 \
  --image ubuntu-24.04 \
  --location $HCLOUD_LOCATION
```

Remember passwd after this next command

```bash
hcloud server enable-rescue talos-image-builder --type linux64
```

```bash
hcloud server reboot talos-image-builder
```

You will need the passwd from previous step.

```bash
BUILDER_IP=$(hcloud server ip talos-image-builder) && \
ssh -o StrictHostKeyChecking=no root@$BUILDER_IP <<EOF
curl -LO "https://factory.talos.dev/image/${SCHEMATIC_ID}/${TALOS_VERSION}/hcloud-amd64.raw.xz"
xz -d -c hcloud-amd64.raw.xz | dd of=/dev/sda bs=4M status=progress
sync
EOF
```

```bash
hcloud server shutdown talos-image-builder

```bash
hcloud server create-image talos-image-builder \
  --type snapshot \
  --description "Talos ${TALOS_VERSION}" \
  --label "caph-image-name=talos-${TALOS_VERSION}"
```

```bash
hcloud server delete talos-image-builder
```

```bash
hcloud image list --type snapshot
```

If you have multiple snapshots.

```bash
IMAGE_IDS="$(hcloud image list --type snapshot | grep -i talos | awk '{print $1}')"
for imageId in "${IMAGE_IDS}" ; do
  hcloud image describe "${imageId}" -o json | \
    jq ".id , .description , .labels"
done

```
