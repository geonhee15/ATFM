import Foundation

/// JavaScript injected into every YouTube Shorts tab. It lives in `window.__atfmAuto` across the
/// SPA navigations, counts full plays of the current Short and moves on to the next one.
/// Called as `(agent)({repeat: N, enabled: bool})`; returns a JSON status string.
/// It disables itself 15 s after the last call, so a quit ATFM never leaves it running.
enum ShortsAgent {
    static let source: String = {
        let lines = [
            "(function(cfg){",
            "var W=window,S=W.__atfmAuto;",
            "if(!S){",
            "S=W.__atfmAuto={cfg:{repeat:1,enabled:true},id:null,plays:0,lastT:0,t:0,d:0,advanced:0,advancedId:null,lastAdvanceAt:0,pendingId:null,pendingSince:0,step:0,lastPing:Date.now(),method:'',log:[]};",
            "S.currentId=function(){var m=location.pathname.match(/\\/shorts\\/([\\w-]+)/);return m?m[1]:null};",
            "S.activeVideo=function(){var vs=document.querySelectorAll('video'),v=null,i;for(i=0;i<vs.length;i++){var x=vs[i];if(!x.paused&&x.readyState>2&&x.clientWidth>0){v=x;break}}if(!v){for(i=0;i<vs.length;i++){if(vs[i].clientWidth>0&&vs[i].duration>0){v=vs[i];break}}}return v};",
            "S.clickNext=function(){var b=document.querySelector('#navigation-button-down button')||document.querySelector('button[aria-label=\"Next video\"]')||document.querySelector('button[aria-label=\"\\ub2e4\\uc74c \\ub3d9\\uc601\\uc0c1\"]');if(b){b.click();return true}return false};",
            "S.scrollNext=function(){var c=document.querySelector('#shorts-container');if(c){c.scrollBy({top:c.clientHeight,behavior:'smooth'});return true}return false};",
            "S.keyNext=function(){var e=new KeyboardEvent('keydown',{key:'ArrowDown',code:'ArrowDown',keyCode:40,which:40,bubbles:true,cancelable:true});(document.activeElement||document.body).dispatchEvent(e);document.dispatchEvent(e)};",
            "S.tryStep=function(reason){var how;if(S.step===0){how=S.clickNext()?'button':'button-missing'}else if(S.step===1){how=S.scrollNext()?'scroll':'scroll-missing'}else{S.keyNext();how='key'}S.method=how;S.log.push(new Date().toISOString().slice(11,19)+' '+reason+' '+how+' '+S.pendingId);if(S.log.length>20)S.log.shift();S.step++};",
            "S.advance=function(reason){var now=Date.now();if(S.advancedId===S.id||now-S.lastAdvanceAt<1500)return;S.advancedId=S.id;S.lastAdvanceAt=now;S.pendingId=S.id;S.pendingSince=now;S.step=0;S.tryStep(reason)};",
            "S.tick=function(){",
            "if(!S.cfg.enabled||Date.now()-S.lastPing>15000)return;",
            "var id=S.currentId();if(!id)return;",
            "if(id!==S.id){S.id=id;S.plays=0;S.lastT=0;S.advancedId=null;if(S.pendingId&&S.pendingId!==id){S.advanced++;S.pendingId=null}}",
            "else if(S.pendingId===id&&Date.now()-S.pendingSince>1500){if(S.step<3){S.pendingSince=Date.now();S.tryStep('retry')}else{var vv=S.activeVideo();if(vv){vv.loop=true;if(vv.ended)vv.play()}S.pendingId=null;S.advancedId=null;S.method='stuck'}}",
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
            "S.cfg.repeat=cfg.repeat;S.cfg.enabled=cfg.enabled;S.lastPing=Date.now();",
            "if(!cfg.enabled){var v2=S.activeVideo();if(v2&&!v2.loop)v2.loop=true}",
            "return JSON.stringify({id:S.id,plays:S.plays,t:Math.round(S.t*10)/10,d:Math.round(S.d*10)/10,advanced:S.advanced,title:document.title,method:S.method,repeat:S.cfg.repeat});",
            "})",
        ]
        return lines.joined(separator: " ")
    }()

    static func call(repeat count: Int, enabled: Bool) -> String {
        "\(source)({repeat:\(max(1, count)),enabled:\(enabled ? "true" : "false")})"
    }
}
