// Location is a shopping suggestion, never an authorization or KYC signal.
export function GET(request) {
 const value=request.headers.get('x-vercel-ip-country')||'';
 return Response.json({country:/^[A-Z]{2}$/.test(value)?value:null},{headers:{'Cache-Control':'private, no-store','Vercel-CDN-Cache-Control':'no-store','CDN-Cache-Control':'no-store','Vary':'x-vercel-ip-country'}});
}
