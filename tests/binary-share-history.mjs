import assert from 'node:assert/strict';
import {mkdir,writeFile,cp} from 'node:fs/promises';

// Anonymized snapshots of both posted production results; entitlement has already
// been applied to awarded_shares, so BP / 100 is not the share count for everyone.
const payouts=[
 {id:'share-a',method:'binary_pool_share',status:'posted',payable_amount:104,created_at:'2026-11-16T20:34:47Z',source_kind:'Binary pool cycle',calculation_trace:{awarded_shares:10.4,share_price:10,consumed_each_side:1040,package_entitlement_snapshot:1}},
 {id:'share-b',method:'binary_pool_share',status:'posted',payable_amount:72,created_at:'2026-11-16T20:34:47Z',source_kind:'Binary pool cycle',calculation_trace:{awarded_shares:7.2,share_price:10,consumed_each_side:900,package_entitlement_snapshot:.8}}
];
export async function run({q,w,dom}){
 q.setAdmin(false);q.setSession({user:{id:'qa'}});q.resetHistoryFilters();
 const render=rows=>{q.setEarningData(rows,[],'PREMIUM');q.setEarningFilter('all');q.setMobileEarning('total','binary_pool_share');q.renderEarningHistory();};
 const mobile=()=>q.el('earningsTable').querySelector('.mobile-earning-cycles');
 const desktop=()=>q.el('desktopEarningHistory');
 const expand=()=>{const button=desktop().querySelector('[data-desktop-earning-day]');if(button.getAttribute('aria-expanded')!=='true')button.click();return desktop().querySelector('.earning-expanded-row');};
 for(const payout of payouts){
  render([payout]);const expected=payout.calculation_trace;
  const badges=mobile().querySelectorAll('.binary-share-formula .binary-share-tag');
  assert.deepEqual([...badges].map(n=>n.textContent),[expected.awarded_shares.toFixed(2)+' shares','10.00 MIO']);
  assert.equal(mobile().querySelector('.binary-share-bp').textContent,expected.consumed_each_side.toFixed(2)+' BP matched');
  assert.match(mobile().querySelector('.earning-mobile-title').textContent,new RegExp('\\+'+payout.payable_amount.toFixed(2)+' MIO'));
  const row=expand().querySelector('.binary-share-event');
  assert.equal(row.querySelector('.binary-share-calculation').colSpan,4);
  assert.equal(row.querySelector('.binary-share-matched').colSpan,3);
  assert.equal([...row.cells].reduce((n,cell)=>n+cell.colSpan,0),11);
  assert.equal(row.cells[2].textContent,payout.payable_amount.toFixed(2));
  assert.equal(row.cells[4].textContent,payout.payable_amount.toFixed(2));
  assert.deepEqual([...row.querySelectorAll('.binary-share-formula .binary-share-tag')].map(n=>n.textContent),[...badges].map(n=>n.textContent));
  assert.equal(row.querySelector('.binary-share-bp').textContent,mobile().querySelector('.binary-share-bp').textContent);
  assert.doesNotMatch(row.textContent,/Unavailable|NaN/);
  q.showEarningDetails(payout);
  const receipt=q.el('historyRecordDialog');
  const field=label=>[...receipt.querySelectorAll('dl>div')].find(n=>n.querySelector('dt')?.textContent===label)?.querySelector('dd').textContent;
  assert.equal(field('Binary shares earned'),expected.awarded_shares.toFixed(2));
  assert.equal(field('Matched Left BP'),expected.consumed_each_side.toFixed(2)+' BP');
  receipt.remove();
  q.setEarningFilter('binary_pool_share');q.renderEarningHistory();
  assert.match(q.el('earningsTable').querySelector('.compact-history tbody').textContent,new RegExp(expected.awarded_shares.toFixed(2)));
 }
 console.log('PASS both accounts: saved shares, historical rate, entitlement-weighted BP, desktop spans, mobile badges and receipt parity');
 render(payouts.map((row,i)=>({...row,created_at:`2026-11-${16-i}T20:34:47Z`,calculation_trace:i?JSON.stringify({...row.calculation_trace,share_price:8}):row.calculation_trace})));
 assert.deepEqual([...mobile().querySelectorAll('.binary-share-formula .binary-share-tag')].map(n=>n.textContent),['10.40 shares','10.00 MIO','7.20 shares','8.00 MIO']);
 const legacy={...payouts[0],calculation_trace:{completed_shares:10.04,gross_share_value:10.125,consumed_each_side:1004}};
 render([legacy]);assert.match(mobile().textContent,/10\.04 shares/);assert.match(mobile().textContent,/10\.125 MIO/);
 render([{...legacy,calculation_trace:{awarded_shares:10.0001,completed_shares:99,share_price:0.0001,consumed_each_side:0}}]);
 assert.match(mobile().textContent,/10\.0001 shares/);assert.match(mobile().textContent,/0\.0001 MIO/);assert.match(mobile().textContent,/0\.00 BP matched/);
 for(const trace of [{},'{bad json',null,{awarded_shares:'<img src=x>',share_price:'Infinity'}]){
  render([{...payouts[0],calculation_trace:trace}]);
  assert.match(mobile().textContent,/Unavailable shares/);assert.doesNotMatch(mobile().textContent,/0\.00 shares|NaN|Infinity/);
  assert.equal(mobile().querySelector('.binary-share-formula img'),null);
 }
 console.log('PASS historical/string traces, exact fractional values, no current-rate substitution or invented zero shares');
 const other={id:'gen',method:'generation',generation:2,payable_amount:1.25,status:'posted',created_at:payouts[0].created_at,source_kind:'Plan activation'};
 render([payouts[0],other]);
 let rows=expand().querySelectorAll('tbody>tr');assert.equal(rows.length,2);assert.equal(rows[1].cells.length,11);assert.match(rows[1].textContent,/1\.25.*Level 2/);
 render([{...payouts[0],source_activation_id:'same-event'},{...other,source_activation_id:'same-event'}]);
 rows=expand().querySelectorAll('tbody>tr');assert.equal(rows.length,1);assert.equal(rows[0].cells.length,11);assert.equal(rows[0].querySelector('[colspan]'),null);assert.match(rows[0].textContent,/1\.25/);
 // Filters retain the ordinary three-column layout and correct totals.
 render([payouts[1]]);const select=desktop().querySelector('[data-desktop-bonus-filter]');select.value='binary_pool_share';select.dispatchEvent(new w.Event('change',{bubbles:true}));
 assert.equal(expand().querySelector('tbody>tr').cells.length,3);assert.match(desktop().querySelector('.desktop-earning-total').textContent,/72\.00 MIO/);
 console.log('PASS ordinary/mixed bonus rows and filtered totals preserved');

 if(process.env.MIO_BINARY_LAYOUT){
  const out=process.env.MIO_BINARY_LAYOUT;
  q.setProfile({user_id:'qa',full_name:'Preview member',member_code:'MIO-PREVIEW',country_code:'PK'});q.updateAuthNavigation();q.setRouteReady(false);q.go('earnings');
  const reset=desktop()?.querySelector('[data-desktop-bonus-filter]');if(reset){reset.value='all';reset.dispatchEvent(new w.Event('change',{bubbles:true}));}
  render([payouts[0],other]);expand();w.document.documentElement.classList.remove('route-restoring');
  const copy=new w.DOMParser().parseFromString(dom.serialize(),'text/html');copy.querySelectorAll('script').forEach(s=>s.remove());
  await mkdir(out+'/dist',{recursive:true});await mkdir(out+'/.openai',{recursive:true});await cp('dist',out+'/dist',{recursive:true});
  await writeFile(out+'/.openai/hosting.json',JSON.stringify({static:{directory:'dist'}}));
  await writeFile(out+'/dist/snapshot.html','<!doctype html>'+copy.documentElement.outerHTML);
  await writeFile(out+'/dist/index.html',`<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><title>Binary share layout verification</title><style>body{margin:0;font:14px system-ui;background:#e9f0ed}header{padding:10px;background:white}iframe{display:block;border:1px solid #aaa;margin:10px auto;background:white}</style><header><label>Viewport <select id="viewport"><option value="1366,768">Laptop 1366</option><option value="1024,768">Laptop 1024</option><option value="390,844">Mobile 390</option><option value="360,780">Mobile 360</option><option value="320,720">Mobile 320</option></select></label></header><iframe id="preview" title="Binary share history" src="/snapshot.html" width="1366" height="768"></iframe><script>document.getElementById('viewport').onchange=function(){const [width,height]=this.value.split(',');const f=document.getElementById('preview');f.width=width;f.height=height;}</script>`);
  console.log('Layout fixture ready:',out);
 }
}
