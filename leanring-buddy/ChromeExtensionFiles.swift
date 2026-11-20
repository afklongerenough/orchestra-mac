//
//  ChromeExtensionFiles.swift
//  leanring-buddy
//
//  The Orchestra Chrome extension (Manifest V3), written out to
//  ~/Orchestra/ChromeExtension when the user sets it up. It connects to
//  Orchestra over a local WebSocket (127.0.0.1 only) and does what
//  BrowserControl asks inside the active tab: read the page, click, type,
//  scroll, go back, open, list/switch tabs, and attach a file to an upload
//  field (through Chrome's debugger API, so it works on any site).
//
//  The "key" fixes the extension's id (ahfdnphbhdjokpkecfbhdhpcoldpogfh)
//  so Orchestra can check who's connecting. It's a public key, not a secret.
//

import Foundation

enum ChromeExtensionFiles {
    static let extensionIdentifier = "ahfdnphbhdjokpkecfbhdhpcoldpogfh"
    static let bridgePort: UInt16 = 43823
    /// Sent in the hello; bump it whenever background.js changes so Orchestra can
    /// tell the user to reload an extension still running old code.
    static let extensionCodeVersion = 2

    static let manifestJSON = """
    {
      "manifest_version": 3,
      "name": "Orchestra",
      "version": "1.2",
      "description": "Lets the Orchestra Mac app read and use the page in your active tab when you ask it to.",
      "key": "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAqo8hwIsewI0ND+G0Fh+KARt4KlovPG+ID3a1jY/L4pYKG5d8Z4vpwjum4VP1CLzDr3MxLEMMKzm8mf9sx84eyMS7W0Da7RlTTtFwVtb+0ASYb15mFckQtv8qBBu9p7iAPloBxY4f7KqEInISVZTruX0leNkp4x3bkP0XX1Kp/M8ISpTqByiJ7PCdDT6+UDGMnrLs464/8VJOvITCWLnlYjyiSA85TcUoio8OTmUHQmIEGHg9qOf9JdFgzhUFSZT0pFwTBUN8atibMLTHOESNmVId+QyZbeIdBP8Qv/XCsmI4SzI8nB5pexY4K8JxScPT2x7pX1MXoOb8SJ3j6QgjYwIDAQAB",
      "permissions": ["scripting", "tabs", "debugger", "alarms"],
      "host_permissions": ["<all_urls>"],
      "background": { "service_worker": "background.js" }
    }
    """

    static func configJavaScript(token: String) -> String {
        "const ORCHESTRA_TOKEN = \"\(token)\";\nconst ORCHESTRA_PORT = \(bridgePort);\n"
    }

    static let backgroundJavaScript = #"""
    importScripts('config.js');

    let orchestraSocket = null;
    let reconnectTimer = null;

    function connectToOrchestra() {
      if (orchestraSocket) return;
      try {
        orchestraSocket = new WebSocket('ws://127.0.0.1:' + ORCHESTRA_PORT + '/');
      } catch (error) {
        orchestraSocket = null;
        scheduleReconnect();
        return;
      }
      orchestraSocket.onopen = () => {
        orchestraSocket.send(JSON.stringify({ type: 'hello', token: ORCHESTRA_TOKEN, version: 2 }));
      };
      orchestraSocket.onmessage = async (event) => {
        let message;
        try { message = JSON.parse(event.data); } catch (error) { return; }
        if (!message || !message.id) return;
        try {
          const result = await handleCommand(message);
          orchestraSocket && orchestraSocket.send(JSON.stringify({ id: message.id, ok: true, result: String(result) }));
        } catch (error) {
          orchestraSocket && orchestraSocket.send(JSON.stringify({ id: message.id, ok: false, error: String((error && error.message) || error) }));
        }
      };
      orchestraSocket.onclose = () => { orchestraSocket = null; scheduleReconnect(); };
      orchestraSocket.onerror = () => {};
    }

    function scheduleReconnect() {
      if (reconnectTimer) return;
      reconnectTimer = setTimeout(() => { reconnectTimer = null; connectToOrchestra(); }, 3000);
    }

    // Keeps the service worker connected (Chrome would otherwise put it to sleep).
    chrome.alarms.create('orchestra-keepalive', { periodInMinutes: 0.5 });
    chrome.alarms.onAlarm.addListener(() => {
      if (!orchestraSocket) connectToOrchestra();
      else if (orchestraSocket.readyState === 1) orchestraSocket.send(JSON.stringify({ type: 'ping' }));
    });
    chrome.runtime.onStartup.addListener(connectToOrchestra);
    chrome.runtime.onInstalled.addListener(connectToOrchestra);
    connectToOrchestra();

    async function activeTab() {
      const [tab] = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
      if (!tab) throw new Error('no active tab');
      return tab;
    }

    async function runInPage(pageFunction, pageArguments) {
      const tab = await activeTab();
      const [injection] = await chrome.scripting.executeScript({ target: { tabId: tab.id }, func: pageFunction, args: pageArguments });
      return injection ? injection.result : '';
    }

    async function handleCommand(message) {
      switch (message.action) {
        case 'read': return await runInPage(readPageInTab, [message.maxText || 3500]);
        case 'describe': return await runInPage(describeElementInTab, [Number(message.elementId)]);
        case 'click': return await runInPage(clickElementInTab, [Number(message.elementId), String(message.expectedLabel || '')]);
        case 'type': return await runInPage(typeIntoElementInTab, [Number(message.elementId), String(message.text || '')]);
        case 'scroll': return await runInPage((screens) => { window.scrollBy(0, window.innerHeight * 0.8 * screens); return 'scrolled'; }, [Number(message.screens) || 1]);
        case 'back': { const tab = await activeTab(); await chrome.tabs.goBack(tab.id); return 'went back'; }
        case 'open': { const tab = await activeTab(); await chrome.tabs.update(tab.id, { url: message.url }); return 'opening ' + message.url; }
        case 'new_tab': { await chrome.tabs.create({ url: message.url }); return 'opened a new tab: ' + message.url; }
        case 'tabs': {
          const tabs = await chrome.tabs.query({ lastFocusedWindow: true });
          return tabs.map((tab) => '[' + tab.id + '] ' + (tab.active ? '(active) ' : '') + tab.title + ' - ' + tab.url).join('\n');
        }
        case 'switch_tab': { await chrome.tabs.update(Number(message.tabId), { active: true }); return 'switched tab'; }
        case 'upload': return await attachFileToUploadField(Number(message.elementId), String(message.path || ''));
        default: throw new Error('unknown action ' + message.action);
      }
    }

    // Attaches a local file to an <input type=file> (works even when the field is hidden).
    async function attachFileToUploadField(elementId, filePath) {
      const tab = await activeTab();
      const debuggee = { tabId: tab.id };
      await chrome.debugger.attach(debuggee, '1.3');
      try {
        const documentResult = await chrome.debugger.sendCommand(debuggee, 'DOM.getDocument', { depth: -1, pierce: true });
        const queryResult = await chrome.debugger.sendCommand(debuggee, 'DOM.querySelector', {
          nodeId: documentResult.root.nodeId, selector: '[data-orch-id="' + elementId + '"]'
        });
        if (!queryResult || !queryResult.nodeId) throw new Error('element ' + elementId + ' is gone; read the page again');
        await chrome.debugger.sendCommand(debuggee, 'DOM.setFileInputFiles', { nodeId: queryResult.nodeId, files: [filePath] });
        return 'attached ' + filePath.split('/').pop();
      } finally {
        try { await chrome.debugger.detach(debuggee); } catch (error) {}
      }
    }

    // ---- These run inside the page (each must be self-contained) ----

    function readPageInTab(maximumTextCharacters) {
      function orchestraLabel(node, maximumLength) {
        const isButtonLikeInput = node.tagName === 'INPUT' && /^(button|submit|reset)$/i.test(node.type || '');
        let imageAlt = '';
        const innerImage = node.querySelector ? node.querySelector('img[alt], svg[aria-label]') : null;
        if (innerImage) imageAlt = innerImage.getAttribute('alt') || innerImage.getAttribute('aria-label') || '';
        const parts = [node.getAttribute('aria-label'), (node.tagName === 'INPUT' || node.tagName === 'TEXTAREA' || node.tagName === 'SELECT') ? '' : node.innerText,
                       isButtonLikeInput ? node.value : '', node.getAttribute('placeholder'), node.getAttribute('title'), node.getAttribute('name'), imageAlt];
        return parts.filter((part) => part).join(' ').replace(/\s+/g, ' ').trim().slice(0, maximumLength || 100);
      }
      document.querySelectorAll('[data-orch-id]').forEach((node) => node.removeAttribute('data-orch-id'));
      const selector = 'a[href], button, input, textarea, [role=button], [role=link], [role=tab], [role=menuitem], [role=checkbox], [role=option], [contenteditable=true], summary';
      const lines = [];
      let nextId = 1;
      for (const node of document.querySelectorAll(selector)) {
        if (nextId > 150) break;
        const isFilePicker = node.tagName === 'INPUT' && node.type === 'file';
        const box = node.getBoundingClientRect();
        if (!isFilePicker) {
          if (box.width < 2 || box.height < 2) continue;
          if (box.bottom < 0 || box.top > window.innerHeight * 2) continue;
          const style = window.getComputedStyle(node);
          if (style.visibility === 'hidden' || style.display === 'none') continue;
        }
        let label = orchestraLabel(node);
        if ((node.tagName === 'INPUT' || node.tagName === 'TEXTAREA') && node.value && !isFilePicker) label += ' (has text)';
        let kind = (node.getAttribute('role') || node.tagName).toLowerCase();
        if (node.tagName === 'INPUT') kind = 'input:' + (node.type || 'text');
        node.setAttribute('data-orch-id', String(nextId));
        const where = isFilePicker ? ' (file picker: use upload)' : (box.top >= 0 && box.bottom <= window.innerHeight ? '' : ' (below, scroll to see)');
        lines.push('[' + nextId + '] ' + kind + ' "' + label + '"' + where);
        nextId++;
      }
      const pageText = (document.body ? document.body.innerText : '').replace(/\n{3,}/g, '\n\n').slice(0, maximumTextCharacters);
      return 'page: ' + document.title + '\naddress: ' + location.href + '\n\nelements:\n' + lines.join('\n') + '\n\npage text:\n' + pageText;
    }

    // SAFETY: describeElementInTab and clickElementInTab must build the label the
    // same way (the Mac checks the first, the page compares it in the second).
    function describeElementInTab(elementId) {
      function orchestraLabel(node, maximumLength) {
        const isButtonLikeInput = node.tagName === 'INPUT' && /^(button|submit|reset)$/i.test(node.type || '');
        let imageAlt = '';
        const innerImage = node.querySelector ? node.querySelector('img[alt], svg[aria-label]') : null;
        if (innerImage) imageAlt = innerImage.getAttribute('alt') || innerImage.getAttribute('aria-label') || '';
        const parts = [node.getAttribute('aria-label'), (node.tagName === 'INPUT' || node.tagName === 'TEXTAREA' || node.tagName === 'SELECT') ? '' : node.innerText,
                       isButtonLikeInput ? node.value : '', node.getAttribute('placeholder'), node.getAttribute('title'), node.getAttribute('name'), imageAlt];
        return parts.filter((part) => part).join(' ').replace(/\s+/g, ' ').trim().slice(0, maximumLength || 100);
      }
      const node = document.querySelector('[data-orch-id="' + elementId + '"]');
      if (!node) return '';
      const fullLabel = orchestraLabel(node, 2000);
      const visibleText = (node.innerText || '').replace(/\s+/g, ' ').trim().slice(0, 2000);
      return (fullLabel + (visibleText && fullLabel.indexOf(visibleText) < 0 ? ' ' + visibleText : '')) || '(no label)';
    }

    function clickElementInTab(elementId, expectedLabel) {
      // Same label as describeElementInTab, worked out again right before the click.
      function orchestraLabel(node, maximumLength) {
        const isButtonLikeInput = node.tagName === 'INPUT' && /^(button|submit|reset)$/i.test(node.type || '');
        let imageAlt = '';
        const innerImage = node.querySelector ? node.querySelector('img[alt], svg[aria-label]') : null;
        if (innerImage) imageAlt = innerImage.getAttribute('alt') || innerImage.getAttribute('aria-label') || '';
        const parts = [node.getAttribute('aria-label'), (node.tagName === 'INPUT' || node.tagName === 'TEXTAREA' || node.tagName === 'SELECT') ? '' : node.innerText,
                       isButtonLikeInput ? node.value : '', node.getAttribute('placeholder'), node.getAttribute('title'), node.getAttribute('name'), imageAlt];
        return parts.filter((part) => part).join(' ').replace(/\s+/g, ' ').trim().slice(0, maximumLength || 100);
      }
      const node = document.querySelector('[data-orch-id="' + elementId + '"]');
      if (!node) return 'missing';
      const fullLabel = orchestraLabel(node, 2000);
      const visibleText = (node.innerText || '').replace(/\s+/g, ' ').trim().slice(0, 2000);
      const currentLabel = (fullLabel + (visibleText && fullLabel.indexOf(visibleText) < 0 ? ' ' + visibleText : '')) || '(no label)';
      // Counters, prices and timestamps tick: compare without digits, first 200 chars.
      const comparable = (text) => text.replace(/\d+/g, '#').slice(0, 200);
      if (comparable(currentLabel) !== comparable(expectedLabel)) return 'changed';
      node.scrollIntoView({ block: 'center' });
      node.focus();
      node.click();
      return 'clicked';
    }

    function typeIntoElementInTab(elementId, text) {
      const node = document.querySelector('[data-orch-id="' + elementId + '"]');
      if (!node) return 'missing';
      if (node.tagName === 'INPUT' && node.type === 'password') return 'password';
      if (node.tagName === 'SELECT') return 'unsupported';
      if (node.tagName === 'INPUT' && /^(file|checkbox|radio|submit|button|image|reset|hidden|range|color)$/i.test(node.type || '')) return 'unsupported';
      if (node.tagName !== 'INPUT' && node.tagName !== 'TEXTAREA' && !node.isContentEditable) return 'unsupported';
      node.scrollIntoView({ block: 'center' });
      node.focus();
      if (node.isContentEditable) {
        document.execCommand('selectAll', false, null);
        document.execCommand('insertText', false, text);
      } else {
        const prototype = node.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
        const descriptor = Object.getOwnPropertyDescriptor(prototype, 'value');
        if (descriptor && descriptor.set) { descriptor.set.call(node, text); } else { node.value = text; }
        node.dispatchEvent(new Event('input', { bubbles: true }));
        node.dispatchEvent(new Event('change', { bubbles: true }));
      }
      return 'typed';
    }
    """#
}
