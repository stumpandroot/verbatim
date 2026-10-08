(() => {
  'use strict';
  const $ = (id) => document.getElementById(id);
  const demoOnly = Boolean(window.VERBATIM_DEMO_ONLY) || location.protocol === 'file:';
  const platforms = ['YouTube','Vimeo','TikTok','Instagram','Facebook','X / Twitter','Reddit','Twitch','Dailymotion','LinkedIn','Loom','Streamable','Rumble','Pinterest','Bluesky'];
  const hosts = {'youtu.be':'YouTube','youtube.com':'YouTube','youtube-nocookie.com':'YouTube','vimeo.com':'Vimeo','tiktok.com':'TikTok','vm.tiktok.com':'TikTok','vt.tiktok.com':'TikTok','instagram.com':'Instagram','facebook.com':'Facebook','fb.watch':'Facebook','x.com':'X / Twitter','twitter.com':'X / Twitter','reddit.com':'Reddit','redd.it':'Reddit','v.redd.it':'Reddit','twitch.tv':'Twitch','clips.twitch.tv':'Twitch','dailymotion.com':'Dailymotion','dai.ly':'Dailymotion','linkedin.com':'LinkedIn','loom.com':'Loom','streamable.com':'Streamable','rumble.com':'Rumble','pinterest.com':'Pinterest','pin.it':'Pinterest','bsky.app':'Bluesky'};
  // Brand marks shipped locally: no remote icon requests needed at runtime.
  const platformSlugs = {'YouTube':'youtube','Vimeo':'vimeo','TikTok':'tiktok','Instagram':'instagram','Facebook':'facebook','X / Twitter':'x','Reddit':'reddit','Twitch':'twitch','Dailymotion':'dailymotion','LinkedIn':'linkedin','Pinterest':'pinterest','Bluesky':'bluesky'};
  function makePlatformBadge(name){
    const slug=platformSlugs[name];
    const badge=elem('span','platform-badge '+(slug?'platform-'+slug:'platform-fallback'));
    badge.setAttribute('aria-hidden','true');
    if(slug){
      const img=elem('img');img.alt='';img.loading='eager';
      img.src=(window.VERBATIM_EMBEDDED_PLATFORM_ICONS||{})[slug]||'/static/platform-icons/'+slug+'.svg';
      badge.append(img);
    } else {
      if(name==='File'){const img=elem('img');img.alt='';img.src=iconSrc('mic.svg');badge.append(img);}else badge.textContent=({'Loom':'L','Streamable':'S','Rumble':'R'})[name]||'?';
    }
    return badge;
  }
  const langNames = {en:'English',es:'Spanish',fr:'French',de:'German',pt:'Portuguese',it:'Italian',ja:'Japanese',ko:'Korean',zh:'Chinese',hi:'Hindi',ar:'Arabic'};
  const sourceNames = {creator_captions:'Creator captions',platform_captions:'Captions from the platform (origin unknown)',auto_captions:'Automatic captions',speech_recognition:'Speech recognition (may contain errors)'};
  const viewNames = {original:'Original transcript',cleaned:'Cleaned transcript (AI-edited)',summary:'Key points (AI-generated)',review:'Review flags (AI-generated)'};
  const activeJobKey='verbatim_active_job';
  let caps=null; // filled from /api/capabilities; null when unknown or in the offline preview
  const sample = {
    id:'verbatim-sample',demo:true,title:'The work behind a meaningful brand story',platform:'YouTube',source_type:'auto_captions',url:'',duration:226,detected_language:'en',refine_status:'completed',
    segments:[
      {start:0,end:15,text:'When people talk about a great brand, they often focus on the logo or the colors. But the strongest brands usually begin with something much more human: a clear reason to exist.'},
      {start:15,end:31,text:'A story helps people understand what you believe, not just what you sell. And that means listening before you start designing anything.'},
      {start:31,end:49,text:'The first question I ask is, who is this really for? If we cannot answer that with specificity, we are probably trying to speak to everyone, and reaching nobody.'},
      {start:49,end:68,text:'Then we listen to customers in their own words. What are they struggling with? What have they already tried? And what would change if they finally solved the problem?'},
      {start:68,end:88,text:'Those answers are the foundation. We are not inventing some beautiful story out of thin air. We are trying to uncover the true story that is already there.'},
      {start:88,end:105,text:'There is an important difference between being clever and being clear. Clever campaigns can get attention. Clear communication helps the right people make decisions.'},
      {start:105,end:124,text:'For example, a workshop owner might tell us that they make custom furniture. But their customers talk about the dining table where their family gathers every Sunday.'},
      {start:124,end:146,text:'Both of those things are true. The second is just more meaningful, because it connects the product to something people already care about.'},
      {start:146,end:167,text:'Once we have that, the visuals and the film and the website start to work together. Every part reinforces the same promise instead of telling a different story.'},
      {start:167,end:189,text:'I also think it matters to keep the language honest. Do not say something you cannot back up. People can tell when a company is performing instead of being itself.'},
      {start:189,end:207,text:'The best process is collaborative. The client knows their business, their customers know the experience, and our job is to help bring those perspectives into focus.'},
      {start:207,end:226,text:'So start with listening, find the truth, say it clearly, and then make something worth remembering. Everything else builds from there.'}
    ],
    cleaned_text:'Great brands begin with a clear reason to exist, not just a logo or a color palette. A meaningful brand story communicates what a company believes, rather than only describing what it sells.\n\nThe first step is understanding the audience. Who is the work really for? Listening to customers reveals their struggles, previous attempts at solving a problem, and the change they hope to experience. Those insights form the foundation of an authentic story.\n\nClear communication often matters more than clever advertising. A furniture maker sells custom tables, but customers may be buying the place where their family gathers. Connecting the product to that human meaning makes the message more relevant.\n\nOnce the story is clear, the visual identity, film, and website can reinforce the same promise. The language must remain honest and specific. The strongest process brings together the company’s knowledge, the customers’ lived experience, and the creative team’s perspective.\n\nBegin by listening. Find the truth. Say it clearly. Then create something worth remembering.',
    summary_points:[{point:'A compelling brand story begins with a genuine purpose, not surface-level aesthetics.',time_seconds:0},{point:'Identify a specific audience and use the customers’ own words to uncover their needs.',time_seconds:31},{point:'Prioritize clear communication over cleverness; connect the product to a human outcome.',time_seconds:88},{point:'Use the same authentic promise across film, identity, and website.',time_seconds:146},{point:'Keep claims honest and build the story collaboratively.',time_seconds:167}],
    review_flags:[{phrase:'custom furniture',reason:'Check that this is the exact product category the speaker described.',time_seconds:105},{phrase:'every Sunday',reason:'Verify this quoted detail before using it in published marketing.',time_seconds:105}]
  };
  let screen='home', activeTab='original', current=null, jobId=null, actionToken=0, toastTimeout=null;
  const storageKey='verbatim_v4_saved';
  let saved=[];
  try { const val=JSON.parse(localStorage.getItem(storageKey)||'[]'); if(Array.isArray(val)) saved=val.slice(0,25); } catch { saved=[]; }
  function store(){ try{localStorage.setItem(storageKey,JSON.stringify(saved));}catch{if(!demoOnly)notify('Storage is unavailable on this device.');} }
  function elem(tag,cls,text){const e=document.createElement(tag);if(cls)e.className=cls;if(text!==undefined)e.textContent=text;return e;}
  function replace(el,...content){el.replaceChildren(...content);}
  let pendingConfirm=null;
  function confirmAction(message,key){if(!demoOnly)return confirm(message);if(pendingConfirm===key){pendingConfirm=null;return true;}pendingConfirm=key;notify(message+' Tap again to confirm.');setTimeout(()=>{if(pendingConfirm===key)pendingConfirm=null;},4000);return false;}
  function notify(message){const t=$('toast');t.textContent=message;t.classList.add('visible');clearTimeout(toastTimeout);toastTimeout=setTimeout(()=>t.classList.remove('visible'),2700);}
  function shortTime(t){let s=Math.max(0,Math.floor(Number(t)||0));return `${String(Math.floor(s/60)).padStart(2,'0')}:${String(s%60).padStart(2,'0')}`;}
  function fullTime(t){let s=Math.max(0,Math.floor(Number(t)||0));return `${String(Math.floor(s/3600)).padStart(2,'0')}:${shortTime(s%3600)}`;}
  function getText(segs){return (segs||[]).map(x=>x.text||'').join(' ').trim();}
  function words(s){return (s.match(/\S+/g)||[]).length;}
  function safePlatform(url){try{const u=new URL(url);if(u.protocol!=='https:'||u.username||u.password)return null;const host=u.hostname.toLowerCase().replace(/\.$/,'');let key=host.replace(/^www\./,'').replace(/^m\./,'').replace(/^music\./,'').replace(/^player\./,'');return hosts[key]||null;}catch{return null;}}
  let swipeNav=null;
  function navigate(page,opts={}){swipeNav=opts.swipe||null;screen=page;document.body.classList.toggle('vb-home-view',page==='home');for(const section of document.querySelectorAll('.page')){const on=section.id==='page-'+page;section.classList.toggle('active',on);section.style.transform='';section.style.opacity='';section.classList.remove('swipe-in-left','swipe-in-right');if(on){if(swipeNav){for(const k of section.querySelectorAll('.vb-in'))k.classList.remove('vb-in');void section.offsetWidth;section.classList.add('swipe-in-'+swipeNav);}else staggerIn(section);}}for(const b of document.querySelectorAll('[data-view]')){const on=b.dataset.view===page;b.classList.toggle('selected',on);if(b.classList.contains('mobile-link')||b.classList.contains('nav-link')){if(on)b.setAttribute('aria-current','page');else b.removeAttribute('aria-current');}}document.body.classList.toggle('vb-topnew-hidden',page==='home');if(page==='library')renderLibrary();document.body.classList.remove('bars-compact');moveNavPill();window.scrollTo({top:0,behavior:swipeNav?'instant':'smooth'});swipeNav=null;}
  function updateSavedCount(){ $('libraryCount').textContent=String(saved.length);$('libraryLabelCount').textContent=String(saved.length); }
  function openSample(tab='original'){
    const ticket=++actionToken;jobId=null;current=null;activeTab=tab;navigate('processing');$('processNotice').textContent='Keep this screen open. The bars show stages, not time left.';
    let n=0;const stages=[{p:20,s:'Checking the source',m:'Loading sample transcript content…'},{p:48,s:'Retrieving the text',m:'Matching sample text to timestamps…'},{p:76,s:'Preparing transcript',m:'Showing the sample summary and review notes…'},{p:100,s:'Sample ready',m:'Explore the original, cleaned, and summary views.'}];
    const tick=()=>{if(ticket!==actionToken)return;const st=stages[n++];drawProgress(st.p,st.s,st.m);if(n<stages.length)setTimeout(tick,460);else setTimeout(()=>{if(ticket!==actionToken)return;current=structuredClone(sample);renderResult();showReady(true);navigate('result');},460);};tick();
  }
  function drawProgress(percent,stage,message){$('processFill').style.width=`${Math.min(100,Math.max(0,percent))}%`;$('processPercent').textContent=`${Math.round(percent)}%`;$('processBar').setAttribute('aria-valuenow',String(Math.round(percent)));$('processStage').textContent=stage;$('processMessage').textContent=message;let index=percent<34?0:percent<80?1:2;$('stageBars').dataset.stage=String(percent>=100?3:index);for(const [i,item] of [...$('stepList').children].entries()){const marker=item.firstElementChild;marker.className='step-marker '+(i<index?'done':i===index?'current':'');marker.textContent=i<index?'':String(i+1);}}
  function rememberJob(id){try{if(id)sessionStorage.setItem(activeJobKey,id);else sessionStorage.removeItem(activeJobKey);}catch{}}
  async function readJson(response){try{return await response.json();}catch{return {};}}
  async function pollJob(id,ticket){
    const stages={queued:'Waiting to start',fetching:'Checking the source',downloading:'Downloading audio',transcribing:'Turning speech into text'};
    while(ticket===actionToken){
      const poll=await fetch(`/api/jobs/${encodeURIComponent(id)}`,{cache:'no-store'});
      if(poll.status===404)throw new Error('This transcript is no longer on the server. Paste the link again.');
      if(!poll.ok)throw new Error('The transcription status could not be retrieved.');
      const j=await poll.json();
      if(j.status==='failed')throw new Error(j.error||'We could not access captions or audio for this video.');
      if(j.status==='completed'){rememberJob(null);current=j;activeTab='original';renderResult();showReady(true);navigate('result');return;}
      drawProgress(j.progress||5,stages[j.status]||'Processing video',j.message||'This can take a little time.');$('processHand').textContent=j.status==='transcribing'?'listening…':j.status==='downloading'?'fetching audio…':'reading captions…';
      await new Promise(resolve=>setTimeout(resolve,1250));
    }
  }
  function showJobError(message){navigate('home');$('formError').textContent=message||'Could not retrieve text from this video.';$('formError').hidden=false;notify('Could not get a transcript from this link.');}
  async function startReal(url){const ticket=++actionToken;current=null;jobId=null;navigate('processing');$('processNotice').textContent='Keep this screen open. The bar shows stages, not time left.';drawProgress(3,'Connecting','Checking access to the video…');try{const response=await fetch('/api/jobs',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({url,language:$('videoLanguage').value})});const data=await readJson(response);if(!response.ok)throw new Error(typeof data.detail==='string'?data.detail:'The video could not be submitted.');jobId=data.job_id;rememberJob(jobId);await pollJob(jobId,ticket);}
    catch(error){if(ticket!==actionToken)return;rememberJob(null);showJobError(error.message);}}
  function uploadFile(file){
    return new Promise((resolve,reject)=>{
      const form=new FormData();form.append('file',file,file.name);form.append('language',$('videoLanguage').value);
      const xhr=new XMLHttpRequest();xhr.open('POST','/api/jobs/upload');
      xhr.upload.onprogress=(e)=>{if(e.lengthComputable)drawProgress(2+28*e.loaded/e.total,'Uploading file',`Sending ${file.name}… ${Math.round(100*e.loaded/e.total)}%`);};
      xhr.onload=()=>{let data={};try{data=JSON.parse(xhr.responseText||'{}');}catch{}if(xhr.status>=200&&xhr.status<300)resolve(data);else reject(new Error(typeof data.detail==='string'?data.detail:'The file could not be uploaded.'));};
      xhr.onerror=()=>reject(new Error('The file could not be uploaded. Check the connection to the Verbatim server.'));
      xhr.send(form);
    });
  }
  async function startUpload(file){
    if(!file)return;
    if(demoOnly){openSample();return;}
    if(caps&&caps.max_upload_mb&&file.size>caps.max_upload_mb*1048576){$('fileNote').textContent=`That file is larger than the ${caps.max_upload_mb} MB limit.`;return;}
    const ticket=++actionToken;current=null;jobId=null;navigate('processing');
    $('processNotice').textContent='The file is transcribed on the computer running Verbatim and deleted when done. Keep this screen open.';
    drawProgress(2,'Uploading file',`Sending ${file.name}…`);
    try{const data=await uploadFile(file);if(ticket!==actionToken)return;jobId=data.job_id;rememberJob(jobId);await pollJob(jobId,ticket);}
    catch(error){if(ticket!==actionToken)return;rememberJob(null);showJobError(error.message);}
  }
  async function resumeJob(){
    let id=null;try{id=sessionStorage.getItem(activeJobKey);}catch{}
    if(!id||demoOnly)return false;
    const ticket=++actionToken;jobId=id;current=null;navigate('processing');
    $('processNotice').textContent='Picking up where you left off. Keep this screen open.';drawProgress(5,'Reconnecting','Checking on your transcript…');
    try{await pollJob(id,ticket);}catch(error){if(ticket!==actionToken)return true;rememberJob(null);showJobError(error.message);}
    return true;
  }
  function linkedTime(t){const b=elem('button','timecode',shortTime(t));b.type='button';b.title='Open video at this timestamp';b.onclick=()=>{if(current?.demo){notify('This sample has no corresponding source video.');return;}if(current?.platform==='File'||!current?.url){notify(`${shortTime(t)} in your file`);return;}let link=current?.url;try{const u=new URL(link);if(current.platform==='YouTube'){u.searchParams.set('t',String(Math.floor(t))+'s');link=u.toString();}else if(current.platform==='Vimeo'){u.hash=`t=${Math.floor(t)}s`;link=u.toString();}window.open(link,'_blank','noopener,noreferrer');}catch{notify('Source video is unavailable.');}};return b;}
  function highlightText(par,text,query){if(!query){par.textContent=text;return;}const index=text.toLowerCase().indexOf(query.toLowerCase());if(index===-1){par.textContent=text;return;}par.append(document.createTextNode(text.slice(0,index)),elem('mark','highlight',text.slice(index,index+query.length)),document.createTextNode(text.slice(index+query.length)));}
  function aiDestination(){
    if(!caps)return 'Creates an AI-edited version and key points. The original stays unchanged.';
    if(caps.ai_provider==='openai')return `Sends this transcript to OpenAI (${caps.ai_model||'model not set'}) to create the cleaned version and key points. The original stays unchanged.`;
    if(caps.ai_provider==='ollama')return `Uses Ollama on the computer running Verbatim (${caps.ai_model||'model not set'}). Nothing leaves that computer. The original stays unchanged.`;
    return 'AI notes are not set up on this server. Start Ollama or set an OpenAI API key, then restart Verbatim.';
  }
  async function loadCapabilities(){if(demoOnly)return;try{const r=await fetch('/api/capabilities',{cache:'no-store'});if(r.ok)caps=await r.json();}catch{caps=null;}if(caps&&caps.ffmpeg===false)$('fileNote').textContent='Audio files only on this server: FFmpeg is not installed, so video files can’t be read.';if(current)renderResult();}
  // Verbie. Poses are built from the <defs> symbols in index.html so he is identical on every screen.
  const NS='http://www.w3.org/2000/svg';
  function vUse(id,attrs={}){const u=document.createElementNS(NS,'use');u.setAttribute('href','#'+id);for(const [k,v] of Object.entries(attrs))u.setAttribute(k,v);return u;}
  function vPath(d,attrs={}){const p=document.createElementNS(NS,'path');p.setAttribute('d',d);p.setAttribute('stroke','#1E2340');p.setAttribute('stroke-width','5');p.setAttribute('stroke-linecap','round');p.setAttribute('fill','none');for(const [k,v] of Object.entries(attrs))p.setAttribute(k,v);return p;}
  function vDot(cx,cy,rx=7,ry=4){const e=document.createElementNS(NS,'ellipse');e.setAttribute('cx',cx);e.setAttribute('cy',cy);e.setAttribute('rx',rx);e.setAttribute('ry',ry);e.setAttribute('fill','#1E2340');return e;}
  function vGroup(cls,...kids){const g=document.createElementNS(NS,'g');if(cls)g.setAttribute('class',cls);for(const k of kids)g.append(k);return g;}
  function verbie(pose){
    const svg=document.createElementNS(NS,'svg');svg.setAttribute('viewBox','0 0 140 170');svg.setAttribute('aria-hidden','true');svg.setAttribute('overflow','visible');svg.style.overflow='visible';
    const eyes=()=>{const g=vGroup('v-eyes',vUse('v-eyes'));return g;};
    const face=(closed=false,flat=false)=>vGroup('',closed?vUse('v-eyes-closed'):eyes(),vUse(flat?'v-flat':'v-smile'));
    let body;
    if(pose==='wave'){
      body=vGroup('v-breathe',vUse('v-body'),face(),vUse('v-legs'),vGroup('v-arm-wave',vPath('M40 70 18 46'),vDot(16,43,6,6)),vPath('M100 80l16 10'),vUse('v-bar-coral',{x:110,y:66}));
    }else if(pose==='listen'){
      body=vGroup('v-nod',vUse('v-body'),face(true),vUse('v-legs'),vUse('v-phones'),vPath('M40 95 30 110'),vPath('M100 95l10 15'));
      svg.append(body);
      const l=vGroup('v-sidebar',vUse('v-bar-coral',{x:8,y:60}));const r=vGroup('v-sidebar',vUse('v-bar-lime',{x:118,y:66}));r.style.animationDelay='.3s';svg.append(l,r);return svg;
    }else if(pose==='cheer'){
      body=vGroup('v-cheer',vUse('v-body'),face(),vUse('v-legs'),vGroup('v-arm-l',vPath('M40 60 18 30'),vUse('v-bar-coral',{x:6,y:-8,transform:'rotate(-12 14 20)'})),vGroup('v-arm-r',vPath('M100 60l22-30'),vUse('v-bar-lime',{x:118,y:0,transform:'rotate(12 126 20)'})));
    }else if(pose==='sit'){
      body=vGroup('v-breathe',vUse('v-body',{transform:'translate(0 20)'}),vGroup('',vUse('v-eyes',{transform:'translate(0 20)'}),vUse('v-smile',{transform:'translate(0 20)'})),vPath('M56 148c0 8 8 10 20 10h22'),vPath('M84 148c0 8 8 10 20 10h14'),vDot(100,158,8,4.5),vDot(120,158,8,4.5),vPath('M40 102 22 120'),vDot(20,122,6,4),vUse('v-bar-coral',{x:6,y:100,transform:'rotate(-18 14 124)'}),vUse('v-bar-lime',{x:118,y:112,transform:'rotate(18 126 129)'}));
    }else if(pose==='shrug'){
      body=vGroup('',vUse('v-body'),face(false,true),vUse('v-legs'),vPath('M40 80 20 72'),vPath('M100 80l20-8'),vDot(17,70),vDot(123,70),vUse('v-bar-coral',{x:4,y:140,transform:'rotate(-80 12 152)'}));
    }else{
      body=vGroup('v-breathe',vUse('v-body'),face(),vUse('v-legs'),vPath('M40 80 22 100'),vPath('M100 80l18 20'),vDot(20,102,6,4),vDot(120,102,6,4),vUse('v-bar-coral',{x:112,y:104}),vUse('v-bar-lime',{x:128,y:118}));
    }
    svg.append(body);return svg;
  }
  function mountVerbies(root=document){for(const el of root.querySelectorAll('.verbie[data-pose]')){if(!el.firstChild)el.append(verbie(el.dataset.pose));}}
  // Wrap each control's contents so the container holds still while the inside springs.
  function wrapInner(root=document){const sel='.btn,.chip,.link-btn,.hand-btn,.paste-btn,.timecode,.summary-time,.library-open,.library-remove,.mobile-link,.nav-link,.icon-button';for(const el of root.querySelectorAll(sel)){if(el.querySelector(':scope > .inner'))continue;const inner=elem('span','inner');while(el.firstChild)inner.append(el.firstChild);el.append(inner);}}
  new MutationObserver(muts=>{for(const m of muts)for(const n of m.addedNodes)if(n.nodeType===1)wrapInner(n.parentNode||n);}).observe(document.body,{childList:true,subtree:true});
  // Stagger: each element of the active screen arrives on its own, in order; swipes set the direction.
  function staggerIn(section){const stack=section.querySelector('.home-stack,.process-stack,.page-head')?section:section;const kids=[];const top=[...section.children];for(const k of top){if(k.matches('.home-stack,.process-stack,.result-layout'))kids.push(...k.children);else kids.push(k);}let i=0;for(const k of kids){if(k.hidden||k.classList.contains('sr-only'))continue;k.classList.remove('vb-in');void k.offsetWidth;k.style.setProperty('--i',String(i++));k.classList.add('vb-in');}}
  // Press and release feel: squash on pointerdown, overshoot on release, on every control.
  (()=>{const sel='.btn,.link-btn,.hand-btn,.icon-button,.paste-btn,.chip,.timecode,.summary-time,.library-open,.library-remove,.mobile-link,.nav-link,.platform-badge,.verbie-home';let cur=null;
    document.addEventListener('pointerdown',e=>{const el=e.target.closest(sel);if(!el||el.disabled)return;cur=el;el.classList.remove('vb-release');el.classList.add('is-pressed');},{passive:true});
    const release=()=>{if(!cur)return;const el=cur;cur=null;el.classList.remove('is-pressed');void el.offsetWidth;el.classList.add('vb-release');el.addEventListener('animationend',()=>el.classList.remove('vb-release'),{once:true});};
    document.addEventListener('pointerup',release,{passive:true});document.addEventListener('pointercancel',release,{passive:true});
  })();
  // Swipe between Home, Library, and About. The page and the tab bar follow the finger from the first
  // move; on release the next page slides in as one piece. A quick flick counts as a swipe.
  (()=>{const order=['home','library','settings'];let sx=0,sy=0,lx=0,lt=0,vx=0,pts=[],active=false,horiz=null,sec=null,nav=null;
    const skip='input,textarea,select,.chips,dialog,.workspace-body,.transcript';
    document.addEventListener('touchstart',e=>{if(!order.includes(screen)||e.touches.length>1)return;const tgt=e.target.nodeType===1?e.target:null;if(tgt&&tgt.closest(skip))return;
      const t=e.touches[0];sx=lx=t.clientX;sy=t.clientY;lt=performance.now();vx=0;pts=[[lt,sx]];active=true;horiz=null;sec=document.querySelector('.page.active');nav=document.querySelector('.mobile-nav');},{passive:true});
    document.addEventListener('touchmove',e=>{if(!active)return;const t=e.touches[0];const dx=t.clientX-sx,dy=t.clientY-sy;
      if(horiz===null){if(Math.abs(dx)<6&&Math.abs(dy)<6)return;horiz=Math.abs(dx)>Math.abs(dy)*1.15;
        if(horiz){for(const el of document.querySelectorAll('.is-pressed'))el.classList.remove('is-pressed');sec.classList.add('is-dragging');nav&&nav.classList.add('is-dragging');}else{active=false;return;}}
      const now=performance.now();lx=t.clientX;lt=now;pts.push([now,lx]);while(pts.length>2&&now-pts[0][0]>100)pts.shift();vx=(lx-pts[0][1])/Math.max(8,now-pts[0][0]);
      const i=order.indexOf(screen);const edge=(dx>0&&i===0)||(dx<0&&i===order.length-1);
      const move=edge?dx*.18:dx*.42;sec.style.transform=`translate3d(${move.toFixed(1)}px,0,0)`;sec.style.opacity=String(1-Math.min(.35,Math.abs(move)/600));
      if(nav)nav.style.setProperty('--sx',(Math.sign(dx)*Math.min(14,Math.abs(dx)*(edge?.03:.07))).toFixed(1)+'px');},{passive:true});
    const settle=()=>{if(sec){sec.classList.remove('is-dragging');sec.style.transform='';sec.style.opacity='';}if(nav){nav.classList.remove('is-dragging');nav.style.setProperty('--sx','0px');}};
    document.addEventListener('touchend',()=>{if(!active)return;active=false;if(!horiz)return;
      const dx=lx-sx;const i=order.indexOf(screen);const dir=dx<0?1:-1;const next=order[i+dir];
      const commit=next&&(Math.abs(dx)>70||(Math.abs(dx)>24&&Math.abs(vx)>.3&&Math.sign(vx)===Math.sign(dx)));
      if(!commit){settle();return;}
      sec.classList.remove('is-dragging');
      if(nav){nav.classList.remove('is-dragging');nav.style.setProperty('--sx',(dir>0?-10:10)+'px');requestAnimationFrame(()=>requestAnimationFrame(()=>nav.style.setProperty('--sx','0px')));}
      navigate(next,{swipe:dir>0?'left':'right'});},{passive:true});
    document.addEventListener('touchcancel',()=>{if(active){active=false;settle();}},{passive:true});
  })();
  // Bars compact while scrolling down and come back when scrolling up or near the top.
  (()=>{let lastY=scrollY,acc=0,ticking=false;
    const set=(on)=>{if(document.body.classList.contains('bars-compact')!==on)document.body.classList.toggle('bars-compact',on);};
    addEventListener('scroll',()=>{if(ticking)return;ticking=true;requestAnimationFrame(()=>{ticking=false;const y=scrollY;const d=y-lastY;lastY=y;
      if(y<40){acc=0;set(false);return;}
      if(Math.sign(d)!==Math.sign(acc))acc=0;acc+=d;
      if(acc>24)set(true);else if(acc<-18)set(false);});},{passive:true});
  })();
  // Tab bar capsule: one continuous spring moves both edges. The leading edge is critically damped
  // (no overshoot, never leaves the bar's padding); the trailing edge is underdamped, so it lags,
  // then springs inward past rest and settles.
  const reduceMotion=matchMedia('(prefers-reduced-motion: reduce)');
  function slotRect(bar,i,count=3){const cs=getComputedStyle(bar);const pad=parseFloat(cs.paddingLeft)||0;const gap=parseFloat(cs.columnGap||cs.gap)||4;const inner=bar.clientWidth-pad*2;const w=(inner-gap*(count-1))/count;const l=pad+i*(w+gap);return {l,r:l+w,w,min:pad,max:bar.clientWidth-pad};}
  function slidePill(pill,i){
    const bar=pill.parentElement;if(!bar.clientWidth){delete pill.dataset.ready;pill.dataset.i=String(i);return;}const t=slotRect(bar,i);const st=pill._s||(pill._s={L:t.l,R:t.r,vL:0,vR:0,raf:0});
    const prev=Number(pill.dataset.i??i);pill.dataset.i=String(i);
    const draw=()=>{pill.style.left=st.L+'px';pill.style.width=Math.max(0,st.R-st.L)+'px';};
    if(!pill.dataset.ready||reduceMotion.matches||i===prev){cancelAnimationFrame(st.raf);st.L=t.l;st.R=t.r;st.vL=st.vR=0;pill.dataset.ready='1';draw();return;}
    const right=i>prev;
    const lead={k:420,c:2*Math.sqrt(420)};
    const trail={k:210,c:2*0.5*Math.sqrt(210)};
    const pL=right?trail:lead, pR=right?lead:trail;
    cancelAnimationFrame(st.raf);let last=performance.now();
    const step=(now)=>{let dt=Math.min(.032,(now-last)/1000);last=now;
      for(let n=0;n<2;n++){const h=dt/2;
        st.vL+=(-pL.k*(st.L-t.l)-pL.c*st.vL)*h;st.L+=st.vL*h;
        st.vR+=(-pR.k*(st.R-t.r)-pR.c*st.vR)*h;st.R+=st.vR*h;}
      if(st.L<t.min){st.L=t.min;st.vL=0;} if(st.R>t.max){st.R=t.max;st.vR=0;}
      const minW=t.w*.7;if(st.R-st.L<minW){if(right)st.L=st.R-minW;else st.R=st.L+minW;}
      draw();
      const done=Math.abs(st.L-t.l)<.3&&Math.abs(st.R-t.r)<.3&&Math.abs(st.vL)<4&&Math.abs(st.vR)<4;
      if(done){st.L=t.l;st.R=t.r;st.vL=st.vR=0;draw();return;}
      st.raf=requestAnimationFrame(step);};
    st.raf=requestAnimationFrame(step);
  }
  addEventListener('resize',()=>{for(const p of document.querySelectorAll('.nav-pill')){if(!p._s){moveNavPill();continue;}if(p._s){const t=slotRect(p.parentElement,Number(p.dataset.i||0));cancelAnimationFrame(p._s.raf);Object.assign(p._s,{L:t.l,R:t.r,vL:0,vR:0});p.style.left=t.l+'px';p.style.width=(t.r-t.l)+'px';}}});
  // Tab bar capsule slides behind the selected tab.
  function moveNavPill(){const nav=document.querySelector('.mobile-nav');if(!nav)return;let pill=nav.querySelector('.nav-pill');if(!pill){pill=elem('span','nav-pill');pill.setAttribute('aria-hidden','true');nav.prepend(pill);}const links=[...nav.querySelectorAll('.mobile-link')];const i=Math.max(0,links.findIndex(l=>l.classList.contains('selected')));slidePill(pill,i);}
  function burst(host){const r=host.getBoundingClientRect();const b=elem('span','burst');b.style.position='fixed';b.style.left=(r.left+r.width/2)+'px';b.style.top=(r.top+r.height/2)+'px';for(let i=0;i<5;i++)b.append(elem('i'));document.body.append(b);setTimeout(()=>b.remove(),900);}
  // Inline SVG icons so CSS can animate their strokes. Falls back to <img> when fetch is unavailable (file://).
  const iconCache=new Map();
  async function inlineIcons(root=document){
    if(location.protocol==='file:')return;
    const imgs=[...root.querySelectorAll('img[src$=".svg"]:not([data-inlined])')].filter(i=>/\/icons\//.test(i.getAttribute('src')));
    await Promise.all(imgs.map(async img=>{
      const src=img.getAttribute('src');img.dataset.inlined='1';
      try{
        if(!iconCache.has(src))iconCache.set(src,fetch(src).then(r=>r.ok?r.text():''));
        const text=await iconCache.get(src);if(!text||!img.isConnected)return;
        const doc=new DOMParser().parseFromString(text,'image/svg+xml');const svg=doc.documentElement;if(svg.nodeName!=='svg')return;
        svg.setAttribute('class',(img.className||'')+' vb-icon');svg.setAttribute('focusable','false');svg.removeAttribute('role');svg.setAttribute('aria-hidden','true');
        if(img.id)svg.id=img.id;svg.dataset.src=src;
        img.replaceWith(document.adoptNode(svg));
      }catch{}
    }));
  }
  function pop(el){if(!el)return;el.classList.remove('vb-pop');void el.offsetWidth;el.classList.add('vb-pop');}
  new MutationObserver(muts=>{for(const m of muts)for(const n of m.addedNodes)if(n.nodeType===1)inlineIcons(n.matches&&n.matches('img')?n.parentNode:n);}).observe(document.body,{childList:true,subtree:true});
  function iconSrc(name){return (window.VERBATIM_EMBEDDED_ICONS||{})[name] || '/static/icons/'+name;}
  function emptyNote(title,message,kind='transcript'){const div=elem('div','empty-note');const v=elem('span','verbie');v.setAttribute('aria-hidden','true');v.append(verbie(kind==='library'?'sit':kind==='search'?'shrug':'stand'));div.append(v,elem('strong','',title),elem('p','',message));return div;}
  function renderBody(){if(!current)return;const body=$('workspaceBody');body.replaceChildren();const isReady=current.refine_status==='completed';$('searchWrap').hidden=activeTab!=='original';$('transcriptSearch').value=activeTab==='original' ? $('transcriptSearch').value : '';
    for(const b of document.querySelectorAll('[data-tab]')){const selected=b.dataset.tab===activeTab;b.classList.toggle('selected',selected);b.setAttribute('aria-selected',String(selected));}
    if(activeTab==='original'){const q=$('transcriptSearch').value.trim().toLowerCase();const filtered=current.segments.filter(s=>!q||(s.text||'').toLowerCase().includes(q));$('searchCount').textContent=q?`${filtered.length} match${filtered.length===1?'':'es'}`:'';if(!filtered.length){body.append(emptyNote('Nothing found','Try another word or phrase.','search'));return;}for(const s of filtered){const row=elem('div','transcript-segment');const p=elem('p');highlightText(p,s.text||'',q);row.append(linkedTime(s.start||0),p);body.append(row);}return;}
    if(activeTab==='cleaned'){if(!isReady){body.append(emptyNote('Cleaned transcript not created yet','Select “Clean & summarize” to create an AI-edited version. The original stays unchanged.','clean'));return;}body.append(elem('p','state-explain has-leading-icon','AI-edited text may contain errors. Compare important phrases with the original before quoting.'),elem('div','clean-body',current.cleaned_text||'No cleaned transcript was returned.'));return;}
    if(activeTab==='summary'){if(!isReady){body.append(emptyNote('Key points not created yet','Select “Clean & summarize” to create a point-by-point summary.','summary'));return;}const head=elem('div','summary-header');head.append(elem('h3','','Key points from this video'),elem('p','','AI-generated summary. Check important details against the source.'));body.append(head);const pts=current.summary_points||[];if(!pts.length)body.append(emptyNote('No summary points','The AI editor did not return any summary points.','summary'));for(const [i,pt] of pts.entries()){const row=elem('div','summary-item');row.append(elem('span','summary-num',String(i+1).padStart(2,'0')),elem('span','summary-item-content',pt.point));if(pt.time_seconds!=null){const t=linkedTime(pt.time_seconds);t.className='summary-time';row.append(t);}body.append(row);}return;}
    if(activeTab==='review'){if(!isReady){body.append(emptyNote('Phrases to double-check','Use “Clean & summarize” to identify uncertain phrases for review.','review'));return;}const flags=current.review_flags||[];body.append(elem('p','state-explain','These phrases may need review. They are not confirmed errors.'));if(!flags.length){body.append(emptyNote('Nothing flagged','No phrases were identified for manual checking.','review'));return;}for(const flag of flags){const div=elem('div','review-item');div.append(elem('strong','',`“${flag.phrase}”`),elem('p','',flag.reason));if(flag.time_seconds!=null){const wrap=elem('div');wrap.style.marginTop='10px';wrap.append(linkedTime(flag.time_seconds));div.append(wrap);}body.append(div);}}
  }
  let readyTimer=null;
  function showReady(fresh){const b=$('readyBlock');clearTimeout(readyTimer);if(!fresh){b.hidden=true;return;}b.hidden=false;b.classList.remove('is-collapsed');const v=b.querySelector('.verbie');v.replaceChildren(verbie('cheer'));readyTimer=setTimeout(()=>b.classList.add('is-collapsed'),3200);}
  function renderResult(){if(!current)return;const isDemo=!!current.demo;const txt=getText(current.segments);$('resultTitle').textContent=current.title||'Untitled video';$('resultPlatform').textContent=current.platform||'Video';$('resultSource').textContent=sourceNames[current.source_type]||'Transcript';$('resultSource').title=`Source: ${sourceNames[current.source_type]||'Unknown'}. Check against the video before quoting.`;$('resultDuration').textContent=shortTime(current.duration||0);$('resultWords').textContent=`${words(txt).toLocaleString()} words`;$('resultLanguage').textContent=langNames[(current.detected_language||'').split('-')[0]]||current.detected_language||'Unknown';
    $('detailPlatform').textContent=current.platform||'Video';$('detailSourceType').textContent=sourceNames[current.source_type]||'Unknown';$('detailDuration').textContent=shortTime(current.duration||0);$('detailLanguage').textContent=$('resultLanguage').textContent;const source=$('originalVideoLink');const okUrl=!isDemo&&safePlatform(current.url||'');source.hidden=isDemo||!okUrl;source.href=okUrl?current.url:'#';
    setSaveLabel(saved.some(i=>i.id===current.id));const ready=current.refine_status==='completed';const processing=current.refine_status==='processing';const noAi=!isDemo&&caps&&caps.ai_provider==='none';const savedOnly=!isDemo&&!jobId&&!ready;$('refineButton').disabled=ready||processing||noAi||savedOnly;$('refineButton').classList.toggle('is-ready',ready);$('refineButton').classList.toggle('is-processing',processing);($('refineButton').querySelector('.inner')||$('refineButton')).lastChild.textContent=ready?' Notes ready':processing?' Creating notes…':' Clean & summarize';
    $('aiStatusText').textContent=processing?(current.refine_message||'Organizing the cleaned text and the key points…'):ready?'The cleaned transcript and key points are ready. Check important details against the original.':current.refine_status==='failed'?`AI notes failed: ${current.refine_error||'Please try again.'}`:savedOnly?'Saved transcripts can’t be refined later. Paste the link again to create AI notes.':aiDestination();
    $('transcriptSearch').value='';renderBody();}
  async function refine(){if(!current)return;if(current.demo){activeTab='cleaned';renderBody();notify('AI notes are already available in the sample');return;}if(!jobId){notify('This transcript is saved. Reprocess the source to generate AI notes.');return;}if(['completed','processing'].includes(current.refine_status))return;const myJob=jobId;try{const r=await fetch(`/api/jobs/${encodeURIComponent(myJob)}/refine`,{method:'POST'});const j=await r.json();if(!r.ok)throw new Error(j.detail||'AI refinement could not be started.');current.refine_status='processing';renderResult();while(jobId===myJob){await new Promise(resolve=>setTimeout(resolve,1350));const p=await fetch(`/api/jobs/${encodeURIComponent(myJob)}`,{cache:'no-store'});if(!p.ok)throw new Error('AI editor status could not be retrieved.');const data=await p.json();current=data;renderResult();if(['completed','failed'].includes(data.refine_status)){if(data.refine_status==='completed'){activeTab='summary';renderBody();notify('Cleaned transcript and key points ready');}else notify(data.refine_error||'AI notes were not generated. Your original transcript is unchanged.');break;}}}catch(error){notify(error.message||'AI notes could not be generated.');$('aiStatusText').textContent=error.message||'Editor unavailable';$('refineButton').disabled=false;}}
  function currentText(){if(!current)return '';if(activeTab==='cleaned')return current.cleaned_text||'';if(activeTab==='summary')return (current.summary_points||[]).map((p,i)=>`${i+1}. ${p.point}${p.time_seconds!=null?` (${shortTime(p.time_seconds)})`:''}`).join('\n');if(activeTab==='review')return (current.review_flags||[]).map(f=>`“${f.phrase}” — ${f.reason}`).join('\n');return getText(current.segments);}
  // Every text that leaves the app says what it is and where it came from.
  function provenanceHeader(){
    if(!current)return '';
    const isDemo=!!current.demo;const ai=activeTab!=='original';
    const lines=[`${current.title||'Untitled video'}`,
      `View: ${viewNames[activeTab]||activeTab}`,
      `Source: ${isDemo?'Verbatim sample (not a real video)':(current.url||'unknown')}`,
      `Transcript type: ${isDemo?'Example content':(sourceNames[current.source_type]||'Unknown')}`,
      `Exported from Verbatim on ${new Date().toISOString().slice(0,10)}`,
      ai?'Note: AI-edited text. Check important phrases, names, and numbers against the original.':'Note: original transcript as retrieved. Captions and speech recognition can contain errors.'];
    return lines.join('\n')+'\n\n';
  }
  function textWithProvenance(){const body=currentText();return body?provenanceHeader()+body+'\n':'';}
  function subtitle(mode){let out=mode==='vtt'?`WEBVTT\n\nNOTE\nOriginal transcript cues from Verbatim. Source: ${current?.demo?'sample':(current?.url||'unknown')}. Type: ${sourceNames[current?.source_type]||'Unknown'}.\n\n`:'';for(const [i,s] of (current?.segments||[]).entries()){const fmt=(sec)=>{let n=Math.max(0,Math.round(Number(sec||0)*1000));const milli=n%1000;n=Math.floor(n/1000);const ss=n%60;n=Math.floor(n/60);const mm=n%60;const hh=Math.floor(n/60);return `${String(hh).padStart(2,'0')}:${String(mm).padStart(2,'0')}:${String(ss).padStart(2,'0')}${mode==='vtt'?'.':','}${String(milli).padStart(3,'0')}`;};out+=(mode==='srt'?`${i+1}\n`:'')+`${fmt(s.start)} --> ${fmt(s.end||s.start+2)}\n${s.text}\n\n`;}return out;}
  function showExportPreview(filename,text){const d=$('exportDialog');$('exportName').textContent=filename;$('exportText').value=text;d.showModal();}
  function download(ext,text,mime){if(!current)return;if(demoOnly){showExportPreview(`${(current.title||'transcript').slice(0,40)}.${ext}`,text);return;}const filename=(current.title||'verbatim-transcript').normalize('NFKD').replace(/[^\w\s-]/g,'').trim().replace(/\s+/g,'-').slice(0,58)||'transcript';const blob=new Blob([text],{type:mime});const link=URL.createObjectURL(blob);const a=document.createElement('a');a.href=link;a.download=`${filename}.${ext}`;document.body.appendChild(a);a.click();a.remove();setTimeout(()=>URL.revokeObjectURL(link),1000);notify(`${ext.toUpperCase()} exported`);}
  function renderLibrary(){updateSavedCount();const root=$('libraryItems');root.replaceChildren();if(!saved.length){const wrap=elem('div','empty-wrap');wrap.append(emptyNote('Your saved transcripts','Save a transcript to find it here later. Library items stay in this browser.','library'));const tryBtn=elem('button','btn btn-dark btn-sm','Open sample transcript');tryBtn.onclick=()=>openSample();wrap.append(tryBtn);root.append(wrap);return;}for(const item of saved){const row=elem('div','library-card');const thumb=elem('div','library-image');thumb.append(makePlatformBadge(item.platform||''));const main=elem('div','library-card-main');main.append(elem('h3','',item.title||'Untitled video'),elem('p','',`${item.platform||'Video'} · ${shortTime(item.duration||0)} · ${item.refine_status==='completed'?'With AI notes':'Original only'} · Saved in this browser`));const open=elem('button','library-open','Open');open.onclick=()=>{current=structuredClone(item);jobId=null;activeTab='original';renderResult();showReady(false);navigate('result');};const remove=elem('button','library-remove','Remove');remove.onclick=()=>{if(!confirmAction(`Remove “${item.title||'Untitled video'}” from this browser’s library?`,'rm-'+item.id))return;saved=saved.filter(x=>x.id!==item.id);store();renderLibrary();notify('Removed from library');};row.append(thumb,main,open,remove);root.append(row);}}
  function setSaveLabel(isSaved){const button=$('saveButton');button.classList.toggle('is-saved',isSaved);const ic=button.querySelector('img,svg.vb-icon');const want=iconSrc((isSaved?'saved':'save')+'.svg');if(ic&&ic.tagName==='IMG')ic.src=want;else if(ic&&ic.dataset.src!==want){const img=elem('img','save-action-icon');img.alt='';img.src=want;ic.replaceWith(img);}pop(button);const lab=(button.querySelector('.inner')||button).lastChild;lab.textContent=isSaved?' Saved':' Save';button.classList.toggle('is-saved',isSaved);button.title=isSaved?'Saved in this browser. Tap again to update the saved copy.':'Save in this browser';}
  // Save never removes. A second tap refreshes the stored copy (for example after AI notes arrive). Removal lives in the Library with a confirmation.
  function saveTranscript(){if(!current)return;const exists=saved.some(s=>s.id===current.id);const copy=structuredClone(current);if(exists){saved=saved.map(s=>s.id===current.id?copy:s);notify('Saved copy updated');}else{if(saved.length>=25)notify('Library is full (25). The oldest transcript was removed.');saved=[copy,...saved].slice(0,25);notify('Saved in this browser');burst($('saveButton'));}store();updateSavedCount();setSaveLabel(true);}
  for(const nav of document.querySelectorAll('[data-view]'))nav.addEventListener('click',()=>{navigate(nav.dataset.view);pop(nav.querySelector('.vb-icon,img'));});
  for(const n of ['topNew','libraryNew'])$(n).addEventListener('click',()=>{navigate('home');$('videoUrl').focus();});
  $('resultBack').addEventListener('click',()=>navigate('home'));
  $('backDuring').addEventListener('click',()=>navigate('home'));
  $('viewLibraryHome').addEventListener('click',()=>navigate('library'));
  $('sampleButton').addEventListener('click',()=>openSample());$('settingsSample').addEventListener('click',()=>openSample());
  for(const card of document.querySelectorAll('[data-demo]'))card.addEventListener('click',()=>openSample(card.dataset.demo==='clean'?'cleaned':card.dataset.demo));
  $('transcribeForm').addEventListener('submit',(ev)=>{ev.preventDefault();const url=$('videoUrl').value.trim();const platform=safePlatform(url);if(!platform){$('formError').textContent='Paste a complete HTTPS video URL from a supported platform.';$('formError').hidden=false;return;}$('formError').hidden=true;if(demoOnly){openSample();return;}startReal(url);});
  $('videoUrl').addEventListener('input',()=>{
    $('formError').hidden=true;
    const value=$('videoUrl').value.trim();
    const platform=safePlatform(value);
    $('platformDetect').textContent=value ? (platform ? `${platform} link recognized. Captions checked first.` : 'Paste an accessible video URL from a supported service.') : ''; $('platformDetect').classList.toggle('is-recognized',Boolean(platform));const uf=document.querySelector('.url-field');uf.classList.remove('is-recognized');if(platform){void uf.offsetWidth;uf.classList.add('is-recognized');}const slug=platformSlugs[platform];for(const b of document.querySelectorAll('#page-home .platform-badge'))b.classList.remove('is-hit');if(slug){const hit=document.querySelector('#page-home .platform-badge.platform-'+slug);if(hit){void hit.offsetWidth;hit.classList.add('is-hit');}}
  });
  $('pasteButton').addEventListener('click',async()=>{
    try{
      if(!navigator.clipboard?.readText) throw new Error('Clipboard access is unavailable here.');
      const text=(await navigator.clipboard.readText()).trim();
      if(!text) {notify('Clipboard is empty.');return;}
      $('videoUrl').value=text;
      $('videoUrl').dispatchEvent(new Event('input',{bubbles:true}));
      $('videoUrl').focus();
      notify('Link pasted from clipboard');
    }catch{ $('videoUrl').focus();notify('Use iPhone Paste from the text field.'); }
  });
  // Drag and drop anywhere on the page (desktop). Names aren't readable before the drop, so the overlay says what will happen.
  (()=>{const zone=$('dropZone');if(!zone)return;let depth=0;
    const hasFiles=e=>e.dataTransfer&&[...(e.dataTransfer.types||[])].includes('Files');
    document.addEventListener('dragenter',e=>{if(!hasFiles(e))return;e.preventDefault();depth++;const n=e.dataTransfer.items?e.dataTransfer.items.length:1;$('dropTitle').textContent=n>1?`Drop ${n} files here to begin transcription`:'Drop your file here to begin transcription';$('dropNote').textContent=demoOnly?'Audio and video files. The file stays on the computer running Verbatim.':`Audio and video files${caps&&caps.max_upload_mb?` up to ${caps.max_upload_mb} MB`:''}. The file stays on this computer.`;zone.classList.add('is-active');});
    document.addEventListener('dragover',e=>{if(hasFiles(e))e.preventDefault();});
    document.addEventListener('dragleave',e=>{if(!hasFiles(e))return;depth=Math.max(0,depth-1);if(depth===0)zone.classList.remove('is-active');});
    document.addEventListener('drop',e=>{if(!hasFiles(e))return;e.preventDefault();depth=0;zone.classList.remove('is-active');const f=e.dataTransfer.files&&e.dataTransfer.files[0];if(f){navigate('home');startUpload(f);}});
  })();
  $('fileButton').addEventListener('click',()=>{$('fileNote').textContent='';$('fileInput').click();});
  $('fileInput').addEventListener('change',()=>{const f=$('fileInput').files&&$('fileInput').files[0];$('fileInput').value='';startUpload(f);});
  $('transcriptSearch').addEventListener('input',()=>renderBody());
  for(const tab of document.querySelectorAll('[data-tab]'))tab.addEventListener('click',()=>{activeTab=tab.dataset.tab;$('transcriptSearch').value='';renderBody();});
  $('saveButton').addEventListener('click',saveTranscript);
  $('refineButton').addEventListener('click',refine);
  $('copyButton').addEventListener('click',async()=>{if(!current)return;pop($('copyButton'));const text=textWithProvenance();if(!text){notify('Generate this view first.');return;}try{await navigator.clipboard.writeText(text);const cb=$('copyButton');const label=(cb.querySelector('.inner')||cb).lastChild;const old=label.textContent;label.textContent=' Copied';cb.classList.add('vb-done');setTimeout(()=>{label.textContent=old;cb.classList.remove('vb-done');},1400);notify(`Copied: ${viewNames[activeTab]||'transcript'}`);}catch{notify('Clipboard unavailable in this browser. Try export.');}});
  $('downloadTxt').addEventListener('click',()=>{if(!current)return;const text=textWithProvenance();if(!text){notify('Generate this view first.');return;}download('txt',text,'text/plain;charset=utf-8');});
  $('downloadSrt').addEventListener('click',()=>download('srt',subtitle('srt'),'text/plain;charset=utf-8'));
  $('downloadVtt').addEventListener('click',()=>download('vtt',subtitle('vtt'),'text/vtt;charset=utf-8'));
  $('clearLibrary').addEventListener('click',()=>{if(!saved.length){notify('No saved transcripts to remove.');return;}if(confirmAction('Remove all saved transcripts from this browser?','clear-all')){saved=[];store();updateSavedCount();notify('Saved transcripts removed.');}});
  $('platformList').replaceChildren(...platforms.map(name=>{
    const item=elem('span','platform-dialog-item');
    item.append(makePlatformBadge(name),elem('span','platform-dialog-name',name));
    return item;
  }));
  $('closeExport').addEventListener('click',()=>$('exportDialog').close());
  $('copyExport').addEventListener('click',async()=>{try{await navigator.clipboard.writeText($('exportText').value);notify('Copied');}catch{$('exportText').select();notify('Select the text and copy it.');}});
  $('showPlatforms').addEventListener('click',()=>$('platformDialog').showModal());
  $('closePlatforms').addEventListener('click',()=>$('platformDialog').close());
  $('dialogDone').addEventListener('click',()=>$('platformDialog').close());
  $('platformDialog').addEventListener('click',e=>{if(e.target===$('platformDialog'))$('platformDialog').close();});
  wrapInner();updateSavedCount();mountVerbies();navigate('home');requestAnimationFrame(moveNavPill);window.addEventListener('resize',moveNavPill);inlineIcons();loadCapabilities();resumeJob();
})();
