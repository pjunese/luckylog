'use strict';
const {createHash}=require('node:crypto');
const {isIP}=require('node:net');
const APP_IDS=new Set([
 '1:172162771888:android:bf63b0548ac221a38f8475',
 '1:172162771888:android:d5f1f2ab138eba0b8f8475',
 '1:172162771888:ios:0977379e02e81ec58f8475',
 '1:172162771888:ios:4dba0f22a90b06858f8475',
]);
function createNearbySearch({db,http,key,HttpsError}) {
 return async request=>{
  if(!APP_IDS.has(request.app?.appId))throw new HttpsError('unauthenticated','앱 확인에 실패했습니다. 최신 앱에서 다시 시도해주세요.');
  const {latitude,longitude}=request.data||{};
  if(!Number.isFinite(latitude)||!Number.isFinite(longitude)||latitude < 32 || latitude > 40 || longitude < 123 || longitude > 133){
   throw new HttpsError('invalid-argument','국내 위치를 확인해주세요.');
  }
  const identity=request.auth?.uid || request.rawRequest?.ip;
  if(!request.auth && !isIP(identity||''))throw new HttpsError('unavailable','요청을 확인하지 못했습니다.');
  const digest=createHash('sha256').update(`${request.auth?'user':'guest'}:${identity}`).digest('hex');
  const now=Date.now();
  const refs=[db.doc(`request_limits/nearby-${digest}`),db.doc('request_limits/nearby-global')];
  await db.runTransaction(async tx=>{
   const snaps=await tx.getAll(...refs);
   for(let i=0;i<snaps.length;i++){
    const previous=snaps[i].data();
    const active=previous?.expiresAt?.toMillis()>now;
    const count=active?previous.count:0;
    if(count >= (i===0?30:3000))throw new HttpsError('resource-exhausted','검색 요청이 많습니다. 잠시 후 다시 시도해주세요.');
    tx.set(refs[i],{count:count+1,expiresAt:active?previous.expiresAt:new Date(now+(i===0?600000:86400000))});
   }
  });
  try {
   const response=await http.get('https://dapi.kakao.com/v2/local/search/keyword.json',{
    headers:{Authorization:`KakaoAK ${key()}`},
    params:{query:'복권',x:longitude.toFixed(4),y:latitude.toFixed(4),radius:3000,size:15,sort:'distance'},
    timeout:8000,maxRedirects:0,maxContentLength:65536,
   });
   if(!Array.isArray(response.data.documents))throw new Error('Invalid response');
   return {places:response.data.documents.slice(0,15).map(p=>({
    name:String(p.place_name||'').slice(0,200),address:String(p.road_address_name||p.address_name||'').slice(0,300),
    distance:Number.parseInt(p.distance,10)||0,lat:Number(p.y),lng:Number(p.x),
    url:/^https?:\/\/place\.map\.kakao\.com\/[0-9]+$/.test(p.place_url||'') ? p.place_url.replace(/^http:/,'https:') : '',
   })).filter(p=>Number.isFinite(p.lat)&&Number.isFinite(p.lng))};
  } catch(error){
   // Never log axios requests: they contain the service key and user location.
   throw new HttpsError('unavailable','주변 판매점을 불러오지 못했습니다. 잠시 후 다시 시도해주세요.');
  }
 };
}
module.exports={createNearbySearch,APP_IDS};
