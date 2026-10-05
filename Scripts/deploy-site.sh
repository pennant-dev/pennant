#!/bin/zsh
# Publishes www/ (pennant.dev) to the S3 bucket behind CloudFront and refreshes the CDN; unless --site-only, the update
# feed too.
#
# The disk image and the update archive are not uploaded here: they are assets of the GitHub release for the version,
# where every download is counted, and both the site and the feed point at them. Publish that release with its assets
# first (docs/RELEASE.md); this script refuses to publish a feed whose archive isn't reachable yet.
#
# The bucket and the distribution are created once (see www/README.md); their names live in www/.deploy.env, which is
# not committed:
#
#   PENNANT_SITE_BUCKET=pennant-dev-site
#   PENNANT_SITE_DISTRIBUTION=E123EXAMPLE
#
#   Scripts/deploy-site.sh              # site + update feed
#   Scripts/deploy-site.sh --site-only  # site only
set -euo pipefail
cd "$(dirname "$0")/.."

[[ -f www/.deploy.env ]] && source www/.deploy.env
: "${PENNANT_SITE_BUCKET:?Set PENNANT_SITE_BUCKET in www/.deploy.env (see www/README.md)}"
: "${PENNANT_SITE_DISTRIBUTION:?Set PENNANT_SITE_DISTRIBUTION in www/.deploy.env (see www/README.md)}"
S3="s3://$PENNANT_SITE_BUCKET"
VERSION=$(sed -n 's/.*static let string = "\(.*\)"/\1/p' Sources/PennantCore/Version.swift)
RELEASE="https://github.com/pennant-dev/pennant/releases/download/v$VERSION"
SITE_ONLY=""
[[ "${1:-}" == "--site-only" ]] && SITE_ONLY=1

if [[ -z "$SITE_ONLY" ]]; then
  grep -q "$RELEASE/Pennant-$VERSION.dmg" www/index.html || { echo "✗ www/index.html does not link to $RELEASE/Pennant-$VERSION.dmg. Scripts/release.sh updates it."; exit 1; }
  if [[ -f "dist/Pennant-$VERSION.dmg" ]]; then
    SUM=$(shasum -a 256 "dist/Pennant-$VERSION.dmg" | cut -d' ' -f1)
    grep -q "$SUM" www/index.html || { echo "✗ The checksum on the page is not the checksum of dist/Pennant-$VERSION.dmg ($SUM)."; exit 1; }
  fi
fi

echo "→ Pages (short cache)"
aws s3 sync www/ "$S3/" --delete --exclude ".deploy.env" --exclude "README.md" --exclude ".DS_Store" --exclude "assets/*" --exclude "appcast.xml" \
  --cache-control "public, max-age=300" --only-show-errors
echo "→ Pictures and films (long cache)"
LONG="public, max-age=604800"
aws s3 sync www/assets/ "$S3/assets/" --delete --exclude ".DS_Store" --exclude "*.avif" --exclude "*.m4a" --exclude "*.woff2" --cache-control "$LONG" --only-show-errors
# Not every CLI knows AVIF, and a picture served as octet-stream doesn't show.
aws s3 sync www/assets/ "$S3/assets/" --delete --exclude "*" --include "*.avif" --content-type image/avif \
  --cache-control "$LONG" --only-show-errors
# The CLI calls .m4a audio/mp4a-latm, which Safari won't play with nosniff. Copied every time (they're small), so a
# clip already up gets its type corrected too.
aws s3 cp www/assets/ "$S3/assets/" --recursive --exclude "*" --include "*.m4a" --content-type audio/mp4 \
  --cache-control "$LONG" --only-show-errors
# Fonts are the site's own (no font service sees visitors), served as what they are.
aws s3 cp www/assets/ "$S3/assets/" --recursive --exclude "*" --include "*.woff2" --content-type font/woff2 \
  --cache-control "$LONG" --only-show-errors

if [[ -z "$SITE_ONLY" ]]; then
  [[ -f dist/updates/appcast.xml ]] || { echo "✗ dist/updates/appcast.xml not found. Run Scripts/release.sh first."; exit 1; }
  grep -q "$RELEASE/Pennant-$VERSION.zip" dist/updates/appcast.xml || { echo "✗ The update feed does not point at $RELEASE/Pennant-$VERSION.zip."; exit 1; }
  # Apps only hear about a version once its archive is there to download.
  STATUS=$(curl -sL -o /dev/null -r 0-0 -w '%{http_code}' "$RELEASE/Pennant-$VERSION.zip")
  [[ "$STATUS" == "206" || "$STATUS" == "200" ]] || { echo "✗ $RELEASE/Pennant-$VERSION.zip answers $STATUS. Publish the GitHub release with its assets first."; exit 1; }
  echo "→ Update feed"
  aws s3 cp dist/updates/appcast.xml "$S3/appcast.xml" --content-type "application/xml" --cache-control "public, max-age=300" --only-show-errors
fi

echo "→ Refreshing the CDN"
aws cloudfront create-invalidation --distribution-id "$PENNANT_SITE_DISTRIBUTION" --paths "/*" --query "Invalidation.Id" --output text
echo "✓ Published"
