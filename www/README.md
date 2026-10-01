# pennant.dev

The public site: one self-contained page (`index.html`, no build step, no third-party requests). The hero sits on the
night shift's dark ground, under a glow drawn from the pennant ribbon in the logo: the pitch on the left, the Mac's
dashboard and the same agent asking on the iPhone on the right (real screenshots). The live dashboard follows in a section
of its own, and the tour has live demos of memory, computer use, coding runs, workers, skills, connections and teaching.

Preview: `python3 -m http.server 8794 --bind 127.0.0.1 --directory www`, then http://127.0.0.1:8794/.

Every demo is something the app really does, in the app's own words ("You took over · agent paused", Allow on a coding
card, the memory review). People and companies are fictional. Motion stops with reduced motion.

## Publishing

`Scripts/deploy-site.sh` syncs `www/` to the S3 bucket behind CloudFront and refreshes the CDN: pages with a 5-minute
cache, `assets/` with a week. The bucket and the distribution are named in `www/.deploy.env`, which is not committed.

## Hosting

- A private S3 bucket (encrypted, public access blocked) that only the CloudFront distribution can read, through an
  origin access control.
- CloudFront: HTTPS only (HTTP redirects), HTTP/2 and 3, compression, the managed caching and security headers policies
  (HSTS, nosniff, frame options, referrer policy), 403 and 404 answered with `404.html`, and a free ACM certificate for
  pennant.dev and www.pennant.dev.
- DNS in a Route 53 zone: alias A and AAAA records for the apex and `www`, and the certificate's validation records. The
  domain is registered elsewhere, with its name servers pointed at the zone.
