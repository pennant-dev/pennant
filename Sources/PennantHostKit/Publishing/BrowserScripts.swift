import Foundation

/// Pennant's own Playwright scripts (generic ones only; site-specific scripts live in skills and run through
/// `browser_script`). Each reads one JSON object on stdin and prints one JSON object as its last stdout line.
enum BrowserScripts {
    static let prelude = #"""
    import { chromium } from 'playwright';
    import { existsSync, mkdirSync } from 'node:fs';
    const readStdin = async () => { let s = ''; for await (const c of process.stdin) s += c; return JSON.parse(s || '{}'); };
    const out = (o) => { process.stdout.write(JSON.stringify(o) + '\n'); };
    const log = (m) => process.stderr.write(String(m) + '\n');
    const sleep = (ms) => new Promise(r => setTimeout(r, ms));
    const input = await readStdin();
    """#

    /// A page's title, address and visible text (and links), read headlessly with a real browser engine.
    static let read = prelude + #"""
    const browser = await chromium.launch();
    try {
      const page = await browser.newPage({ userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0 Safari/537.36' });
      await page.goto(input.url, { waitUntil: 'domcontentloaded', timeout: 45000 });
      await page.waitForLoadState('networkidle', { timeout: 8000 }).catch(() => {});
      const text = await page.evaluate((links) => {
        const body = document.body ? document.body.innerText : '';
        let out = document.title + '\n' + location.href + '\n\n' + body;
        if (links) out += '\n\nLINKS:\n' + Array.from(document.links).slice(0, 300).map(a => a.innerText.trim().slice(0, 80) + ' -> ' + a.href).join('\n');
        return out;
      }, !!input.links);
      out({ text });
    } catch (e) {
      out({ error: String(e && e.message || e) });
    } finally {
      await browser.close();
    }
    """#

    /// HTML (a string or a file) → PNG at the given size.
    static let render = prelude + #"""
    const browser = await chromium.launch();
    try {
      const page = await browser.newPage({ viewport: { width: input.width || 1080, height: input.height || 1350 }, deviceScaleFactor: input.scale || 1 });
      if (input.htmlFile) await page.goto('file://' + input.htmlFile, { waitUntil: 'networkidle' });
      else await page.setContent(input.html, { waitUntil: 'networkidle' });
      await page.evaluate(() => document.fonts && document.fonts.ready);
      await sleep(250);
      await page.screenshot({ path: input.out, fullPage: false });
      out({ ok: true, out: input.out });
    } catch (e) {
      out({ ok: false, error: String(e && e.message || e) });
    } finally {
      await browser.close();
    }
    """#

    /// Adds cookies (sign-ins imported from the user's Chrome) to Pennant's persistent profile.
    static let addCookies = prelude + #"""
    const ctx = await chromium.launchPersistentContext(input.profile, {
      channel: existsSync('/Applications/Google Chrome.app') ? 'chrome' : undefined,
      headless: true,
    });
    try {
      await ctx.addCookies(input.cookies);
      out({ ok: true, count: input.cookies.length });
    } catch (e) {
      out({ ok: false, error: String(e && e.message || e) });
    } finally {
      await ctx.close();
    }
    """#

    /// Deletes one site's cookies (and its subdomains') from Pennant's persistent profile.
    static let clearCookies = prelude + #"""
    const ctx = await chromium.launchPersistentContext(input.profile, {
      channel: existsSync('/Applications/Google Chrome.app') ? 'chrome' : undefined,
      headless: true,
    });
    try {
      const escaped = input.site.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
      await ctx.clearCookies({ domain: new RegExp('(^|\\.)' + escaped + '$') });
      const left = (await ctx.cookies()).filter(c => c.domain.replace(/^\./, '') === input.site || c.domain.endsWith('.' + input.site)).length;
      out({ ok: left === 0, left, error: left ? `${left} cookie(s) remain` : undefined });
    } catch (e) {
      out({ ok: false, error: String(e && e.message || e) });
    } finally {
      await ctx.close();
    }
    """#
}
