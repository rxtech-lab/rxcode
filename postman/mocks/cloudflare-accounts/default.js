// Synthetic fixtures from Cloudflare's documented List Memberships contract.
const http = require('node:http');
http.createServer((req, res) => {
  const reply = (status, value) => {
    res.writeHead(status, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(value));
  };
  const url = new URL(req.url, 'http://localhost');
  if (req.method === 'GET' && url.pathname === '/accounts/' + 'a'.repeat(32) + '/billable-usage') {
    if (url.search) return reply(400, { success: false });
    if (req.headers.authorization === 'Bearer denied') return reply(403, { success: false, errors: [{ message: 'Authentication error' }] });
    if (req.headers.authorization === 'Bearer malformed') return reply(200, { success: true, result: [{ workersRequests: 5 }] });
    if (req.headers.authorization !== 'Bearer fixture') return reply(401, {});
    return reply(200, { success: true, result: [
      { ServiceName: 'Workers Standard', ConsumedQuantity: 150000, ConsumedUnit: 'requests', BilledCost: 0.75, BillingCurrency: 'USD', CumulatedContractedCost: 0.75, CumulatedPricingQuantity: 4500000 },
      { ServiceName: 'Workers Standard', ConsumedQuantity: 250000, ConsumedUnit: 'requests', BilledCost: 1.25, BillingCurrency: 'USD', CumulatedContractedCost: 2.0, CumulatedPricingQuantity: 4750000 },
      { ServiceName: 'R2 Storage', ConsumedQuantity: 2, ConsumedUnit: 'GB-months', BilledCost: 0.03, BillingCurrency: 'USD', CumulatedContractedCost: 2.03 }
    ] });
  }
  if (req.method !== 'GET' || url.pathname !== '/memberships') return reply(501, {});
  if (req.headers.authorization === 'Bearer denied') return reply(403, { success: false, errors: [{ message: 'Missing memberships.read' }] });
  if (req.headers.authorization === 'Bearer malformed') return reply(200, { success: true });
  if (req.headers.authorization !== 'Bearer fixture') return reply(401, {});
  if (url.searchParams.get('status') !== 'accepted' || url.searchParams.get('per_page') !== '50') return reply(400, {});
  const member = (id, status = 'accepted') => ({ id: 'membership-' + id, status, account: { id, name: 'Account ' + id } });
  const page = url.searchParams.get('page');
  if (page === '1') return reply(200, { success: true, result: Array.from({ length: 50 }, (_, i) => member(String(i).padStart(32, '0'))) });
  if (page === '2') return reply(200, { success: true, result: [member('0'.repeat(32)), member('a'.repeat(32)), member('b'.repeat(32), 'pending')] });
  return reply(200, { success: true, result: [] });
}).listen(process.env.PORT);
