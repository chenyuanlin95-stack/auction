function fmt(n){return '¥'+Number(n||0).toLocaleString('zh-CN')}
function fmtWan(n){const v=Number(n||0)/10000;return (Number.isInteger(v)?v:v.toFixed(1))+' 万'}
function randCode(len=6){const chars='ABCDEFGHJKLMNPQRSTUVWXYZ23456789';let s='';crypto.getRandomValues(new Uint32Array(len)).forEach(n=>s+=chars[n%chars.length]);return s}
function randToken(){const a=new Uint32Array(8);crypto.getRandomValues(a);return Array.from(a,x=>x.toString(16).padStart(8,'0')).join('')}
function cfgOk(){return AUCTION_CONFIG.SUPABASE_URL.startsWith('https://')&&!AUCTION_CONFIG.SUPABASE_URL.includes('PASTE_')&&!AUCTION_CONFIG.SUPABASE_ANON_KEY.includes('PASTE_')}
function makeClient(){if(!cfgOk()) throw new Error('还没配置 Supabase。请先填写 config.js。');return supabase.createClient(AUCTION_CONFIG.SUPABASE_URL,AUCTION_CONFIG.SUPABASE_ANON_KEY,{realtime:{params:{eventsPerSecond:20}}});}
