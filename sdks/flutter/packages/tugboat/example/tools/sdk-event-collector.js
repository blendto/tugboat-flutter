#!/usr/bin/env node
const { WebSocketServer } = require('ws');
const fs = require('fs');
const path = require('path');

const outPath = path.join(__dirname, 'captured-events.json');
const events = [];

const wss = new WebSocketServer({ port: 7832, path: '/sdk' });
wss.on('connection', (ws) => {
  console.log('[sdk-sink] client connected');
  ws.on('message', (raw) => {
    try {
      const msg = JSON.parse(raw.toString());
      if (msg.type === 'event' && msg.payload) {
        events.push(msg.payload);
        const t = msg.payload.type;
        if (['scroll_start', 'scroll_end', 'swipe', 'tap'].includes(t)) {
          console.log(`[event] ${t}`, JSON.stringify({
            id: msg.payload.id,
            relatedEventId: msg.payload.relatedEventId,
            role: msg.payload.targetAnchor?.role,
            sectionLabel: msg.payload.data?.sectionLabel,
            scrolled: msg.payload.data?.scrolled,
            axis: msg.payload.data?.axis,
          }));
        }
      } else if (msg.type === 'session') {
        console.log('[session]', JSON.stringify(msg.payload?.id ?? msg));
      }
    } catch (e) {
      console.error('[sdk-sink] parse error', e.message);
    }
  });
});

process.on('SIGINT', () => {
  fs.writeFileSync(outPath, JSON.stringify(events, null, 2));
  console.log(`[sdk-sink] wrote ${events.length} events to ${outPath}`);
  process.exit(0);
});

console.log('[sdk-sink] listening on ws://127.0.0.1:7832/sdk');
