import Foundation

/// Instagram Reels counterpart of ShortsAgent. Instagram's markup is obfuscated, so everything is
/// found structurally: the playing <video> nearest the viewport centre, its scroll container, and a
/// next-button by aria-label. Advancing tries button → scroll to the next video → ArrowDown.
enum ReelsAgent {
    static let source: String = {
        let lines = [
            "(function(cfg){",
            "var W=window,S=W.__atfmReels;",
            "if(!S){",
            "S=W.__atfmReels={cfg:{repeat:1,enabled:true,comments:false},id:null,plays:0,lastT:0,t:0,d:0,advanced:0,advancedId:null,lastAdvanceAt:0,pendingId:null,pendingSince:0,step:0,lastPing:Date.now(),method:'',log:[],commentsId:null,commentsTries:0,commentsAt:0,commentsOpen:false,videoKey:0};",
            "S.currentId=function(){var m=location.pathname.match(/\\/reels?\\/([A-Za-z0-9_-]+)/);if(m)return m[1];var v=S.activeVideo();return v?('v'+(v.__atfmKey||0)):null};",
            "S.activeVideo=function(){var vs=document.querySelectorAll('video'),best=null,bestD=1e9,mid=W.innerHeight/2;for(var i=0;i<vs.length;i++){var v=vs[i],r=v.getBoundingClientRect();if(r.height<80||r.bottom<0||r.top>W.innerHeight)continue;if(!v.__atfmKey)v.__atfmKey=++S.videoKey;var d=Math.abs((r.top+r.bottom)/2-mid)+(v.paused?400:0);if(d<bestD){bestD=d;best=v}}return best};",
            "S.scroller=function(v){var e=v?v.parentElement:null;while(e&&e!==document.body){var cs=getComputedStyle(e);if(e.scrollHeight>e.clientHeight+10&&/(auto|scroll)/.test(cs.overflowY))return e;e=e.parentElement}return document.scrollingElement||document.documentElement};",
            "S.nextButton=function(){var sel=['button[aria-label=\"Next\"]','button[aria-label=\"\\\\ub2e4\\\\uc74c\"]','[role=button][aria-label=\"Next\"]','[role=button][aria-label=\"\\\\ub2e4\\\\uc74c\"]'];for(var i=0;i<sel.length;i++){var b=document.querySelector(sel[i]);if(b&&b.offsetParent)return b}var svgs=document.querySelectorAll('svg[aria-label=\"Next\"],svg[aria-label=\"\\\\ub2e4\\\\uc74c\"]');for(var j=0;j<svgs.length;j++){var p=svgs[j].closest('button,[role=button],a');if(p&&p.offsetParent)return p}return null};",
            "S.clickNext=function(){var b=S.nextButton();if(b){b.click();return true}return false};",
            "S.scrollNext=function(){var v=S.activeVideo();if(!v)return false;var sc=S.scroller(v);var vs=Array.prototype.slice.call(document.querySelectorAll('video')).filter(function(x){return x.getBoundingClientRect().height>=80}).sort(function(a,b){return a.getBoundingClientRect().top-b.getBoundingClientRect().top});var cur=v.getBoundingClientRect(),target=null;for(var i=0;i<vs.length;i++){if(vs[i].getBoundingClientRect().top>cur.top+20){target=vs[i];break}}var delta=target?(target.getBoundingClientRect().top-cur.top):(cur.height+16);if(sc===document.scrollingElement||sc===document.documentElement){W.scrollBy({top:delta,behavior:'smooth'})}else{sc.scrollBy({top:delta,behavior:'smooth'})}return true};",
            "S.keyNext=function(){var v=S.activeVideo();var sc=v?S.scroller(v):document.body;var e=new KeyboardEvent('keydown',{key:'ArrowDown',code:'ArrowDown',keyCode:40,which:40,bubbles:true,cancelable:true});(document.activeElement||document.body).dispatchEvent(e);if(sc&&sc.dispatchEvent)sc.dispatchEvent(e);document.dispatchEvent(e)};",
            "S.commentsButton=function(){var sel=['svg[aria-label=\"Comment\"]','svg[aria-label=\"\\\\ub313\\\\uae00\"]','svg[aria-label=\"\\\\ub313\\\\uae00 \\\\ub2ec\\\\uae30\"]'];var v=S.activeVideo();var vr=v?v.getBoundingClientRect():null;var best=null,bestD=1e9;for(var i=0;i<sel.length;i++){var list=document.querySelectorAll(sel[i]);for(var j=0;j<list.length;j++){var p=list[j].closest('button,[role=button],a,div[role=button]');if(!p||!p.offsetParent)continue;var r=p.getBoundingClientRect();var d=vr?Math.abs((r.top+r.bottom)/2-(vr.top+vr.bottom)/2):0;if(d<bestD){bestD=d;best=p}}}return best};",
            "S.commentsPanelOpen=function(){var ta=document.querySelector('textarea[aria-label],form textarea');return !!(ta&&ta.offsetParent)};",
            "S.ensureComments=function(){var open=S.commentsPanelOpen();S.commentsOpen=open;if(open||!S.cfg.comments)return;var now=Date.now();if(S.commentsId!==S.id){S.commentsId=S.id;S.commentsTries=0}if(S.commentsTries>=4||now-S.commentsAt<1500)return;var b=S.commentsButton();if(b){S.commentsAt=now;S.commentsTries++;b.click()}};",
            "S.tryStep=function(reason){var how;if(S.step===0){how=S.clickNext()?'button':'button-missing'}else if(S.step===1){how=S.scrollNext()?'scroll':'scroll-missing'}else{S.keyNext();how='key'}S.method=how;S.log.push(new Date().toISOString().slice(11,19)+' '+reason+' '+how+' '+S.pendingId);if(S.log.length>20)S.log.shift();S.step++};",
            "S.advance=function(reason){var now=Date.now();if(S.advancedId===S.id||now-S.lastAdvanceAt<1500)return;S.advancedId=S.id;S.lastAdvanceAt=now;S.pendingId=S.id;S.pendingSince=now;S.step=0;S.tryStep(reason)};",
            "S.tick=function(){",
            "if(!S.cfg.enabled||Date.now()-S.lastPing>15000)return;",
            "var id=S.currentId();if(!id)return;",
            "if(id!==S.id){S.id=id;S.plays=0;S.lastT=0;S.advancedId=null;if(S.pendingId&&S.pendingId!==id){S.advanced++;S.pendingId=null}}",
            "else if(S.pendingId===id&&Date.now()-S.pendingSince>1500){if(S.step<3){S.pendingSince=Date.now();S.tryStep('retry')}else{var vv=S.activeVideo();if(vv){vv.loop=true;if(vv.ended)vv.play()}S.pendingId=null;S.advancedId=null;S.method='stuck'}}",
            "S.ensureComments();",
            "var v=S.activeVideo();if(!v||!(v.duration>0))return;",
            "var t=v.currentTime,d=v.duration;S.t=t;S.d=d;",
            "var last=S.plays+1>=S.cfg.repeat;",
            "if(last&&v.loop)v.loop=false;",
            "var looped=t<S.lastT-1&&S.lastT>d-3;S.lastT=t;",
            "if(looped){S.plays++;if(S.plays>=S.cfg.repeat)S.advance('loop')}",
            "else if(last&&(v.ended||d-t<=0.3))S.advance('end')",
            "};",
            "document.addEventListener('timeupdate',S.tick,true);document.addEventListener('ended',S.tick,true);S.timer=setInterval(S.tick,500)",
            "}",
            "S.cfg.repeat=cfg.repeat;S.cfg.enabled=cfg.enabled;S.cfg.comments=!!cfg.comments;S.lastPing=Date.now();",
            "if(!cfg.enabled){var v2=S.activeVideo();if(v2&&!v2.loop)v2.loop=true}",
            "return JSON.stringify({id:S.id,plays:S.plays,t:Math.round(S.t*10)/10,d:Math.round(S.d*10)/10,advanced:S.advanced,title:document.title,method:S.method,repeat:S.cfg.repeat,comments:S.commentsOpen});",
            "})",
        ]
        return lines.joined(separator: " ")
    }()

    static func call(repeat count: Int, enabled: Bool, comments: Bool = false) -> String {
        "\(source)({repeat:\(max(1, count)),enabled:\(enabled ? "true" : "false"),comments:\(comments ? "true" : "false")})"
    }
}
