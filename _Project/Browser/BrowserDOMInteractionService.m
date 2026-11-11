#import "BrowserDOMInteractionService.h"

#import "BrowserWebView.h"

static NSString * const kInteractiveElementSelector = @"a, button, input, textarea, select, option, label, summary, [role='button'], [onclick], [tabindex]";
static NSString * const kEditableElementSelector = @"input, textarea, select, [contenteditable='true'], [contenteditable=''], [contenteditable]";

@implementation BrowserDOMInteractionService

- (CGPoint)DOMPointForCursorOrigin:(CGPoint)cursorOrigin
                            inView:(UIView *)containerView
                           webView:(BrowserWebView *)webView {
    CGPoint point = [containerView convertPoint:cursorOrigin toView:webView];
    if (point.y < 0.0) {
        return point;
    }

    NSInteger displayWidth = [[webView stringByEvaluatingJavaScriptFromString:@"window.innerWidth"] integerValue];
    if (displayWidth <= 0) {
        return point;
    }

    CGFloat scale = CGRectGetWidth([webView frame]) / (CGFloat)displayWidth;
    if (scale <= 0.0) {
        return point;
    }

    point.x /= scale;
    point.y /= scale;
    return point;
}

- (NSString *)evaluateResolvedElementJavaScriptAtPoint:(CGPoint)point
                                                webView:(BrowserWebView *)webView
                                                   body:(NSString *)body {
    if (webView == nil) {
        return @"";
    }

    NSInteger pointX = (NSInteger)llround(point.x);
    NSInteger pointY = (NSInteger)llround(point.y);
    NSString *script = [NSString stringWithFormat:
                        @"(function(){"
                        "var x=%ld;"
                        "var y=%ld;"
                        "var interactiveSelector=\"%@\";"
                        "var editableSelector=\"%@\";"
                        "function resolveElement(root, px, py) {"
                            "if (!root || typeof root.elementFromPoint !== 'function') { return null; }"
                            "var element = root.elementFromPoint(px, py);"
                            "while (element) {"
                                "if (element.shadowRoot && typeof element.shadowRoot.elementFromPoint === 'function') {"
                                    "var shadowRect = element.getBoundingClientRect();"
                                    "var shadowElement = resolveElement(element.shadowRoot, px - shadowRect.left, py - shadowRect.top);"
                                    "if (shadowElement && shadowElement !== element) {"
                                        "element = shadowElement;"
                                        "continue;"
                                    "}"
                                "}"
                                "if (element.tagName === 'IFRAME') {"
                                    "try {"
                                        "var frameRect = element.getBoundingClientRect();"
                                        "var frameDocument = element.contentDocument;"
                                        "var frameElement = resolveElement(frameDocument, px - frameRect.left, py - frameRect.top);"
                                        "if (frameElement) {"
                                            "element = frameElement;"
                                            "continue;"
                                        "}"
                                    "} catch (error) {}"
                                "}"
                                "return element;"
                            "}"
                            "return null;"
                        "}"
                        "function closestMatch(element, selector) {"
                            "while (element) {"
                                "if (element.matches && element.matches(selector)) { return element; }"
                                "element = element.parentElement;"
                            "}"
                            "return null;"
                        "}"
                        "var resolvedElement = resolveElement(document, x, y);"
                        "var interactiveElement = closestMatch(resolvedElement, interactiveSelector);"
                        "var editableElement = closestMatch(resolvedElement, editableSelector);"
                        "%@"
                        "})()",
                        (long)pointX,
                        (long)pointY,
                        kInteractiveElementSelector,
                        kEditableElementSelector,
                        body];
    return [webView stringByEvaluatingJavaScriptFromString:script] ?: @"";
}

- (NSString *)evaluateEditableElementJavaScriptAtPoint:(CGPoint)point
                                                webView:(BrowserWebView *)webView
                                                   body:(NSString *)body {
    NSString *wrappedBody = [NSString stringWithFormat:
                             @"function browserIsEditableCandidate(element) {"
                                 "if (!element) { return false; }"
                                 "var tagName = element.tagName ? element.tagName.toLowerCase() : '';"
                                 "if (element.matches && element.matches(editableSelector)) { return true; }"
                                 "if (tagName === 'textarea' || tagName === 'select') { return true; }"
                                 "if (element.isContentEditable) { return true; }"
                                 "return false;"
                             "}"
                             "function browserEditableTarget() {"
                                 "var stored = window.__browserLastEditableElement;"
                                 "if (stored && stored.isConnected && browserIsEditableCandidate(stored)) { return stored; }"
                                 "var active = document.activeElement;"
                                 "if (active && browserIsEditableCandidate(active)) {"
                                     "window.__browserLastEditableElement = active;"
                                     "return active;"
                                 "}"
                                 "var candidate = editableElement || interactiveElement || resolvedElement;"
                                 "if (candidate && browserIsEditableCandidate(candidate)) {"
                                     "window.__browserLastEditableElement = candidate;"
                                     "return candidate;"
                                 "}"
                                 "if (candidate && candidate.closest) {"
                                     "var fallback = candidate.closest(editableSelector) || candidate.closest('textarea, select');"
                                     "if (fallback && browserIsEditableCandidate(fallback)) {"
                                         "window.__browserLastEditableElement = fallback;"
                                         "return fallback;"
                                     "}"
                                 "}"
                                 "return null;"
                             "}"
                             "%@",
                             body];
    return [self evaluateResolvedElementJavaScriptAtPoint:point webView:webView body:wrappedBody];
}

- (BOOL)pushScrollAtDOMPoint:(CGPoint)point
                   direction:(CGPoint)direction
                      amount:(CGFloat)amount
                        zone:(CGFloat)zone
                     webView:(BrowserWebView *)webView {
    if (webView == nil) {
        return NO;
    }
    NSString *script = [NSString stringWithFormat:
                        @"(function(){"
                        @"var x=%ld,y=%ld,dx=%ld,dy=%ld,zone=%.2f,amount=%.2f;"
                        @"function okY(v){return v===\"auto\"||v===\"scroll\"||v===\"overlay\";}"
                        @"function okX(v){return okY(v)||v===\"hidden\";}"
                        @"function can(el){"
                        @"var cs=getComputedStyle(el);"
                        @"if(dy!==0&&okY(cs.overflowY)&&el.scrollHeight>el.clientHeight+1){"
                        @"if(dy>0&&el.scrollTop+el.clientHeight<el.scrollHeight-1){return true;}"
                        @"if(dy<0&&el.scrollTop>0){return true;}"
                        @"}"
                        @"if(dx!==0&&okX(cs.overflowX)&&el.scrollWidth>el.clientWidth+1){"
                        @"if(dx>0&&el.scrollLeft+el.clientWidth<el.scrollWidth-1){return true;}"
                        @"if(dx<0&&el.scrollLeft>0){return true;}"
                        @"}"
                        @"return false;"
                        @"}"
                        @"function findPanel(){"
                        @"var el=document.elementFromPoint(x,y);"
                        @"while(el&&el!==document.body&&el!==document.documentElement){"
                        @"if(can(el)){return el;}"
                        @"el=el.parentElement;"
                        @"}"
                        @"return null;"
                        @"}"
                        @"var panel=findPanel();"
                        @"var l=0,t=0,r=window.innerWidth,b=window.innerHeight;"
                        @"if(panel){var rc=panel.getBoundingClientRect();l=rc.left;t=rc.top;r=rc.right;b=rc.bottom;}"
                        @"var dist=dy>0?b-y:(dy<0?y-t:(dx>0?r-x:x-l));"
                        @"if(dist>zone){return \"move\";}"
                        @"if(panel){panel.scrollTop+=dy*amount;panel.scrollLeft+=dx*amount;return \"scrolled\";}"
                        @"var se=document.scrollingElement||document.documentElement;"
                        @"var bt=se.scrollTop,bl=se.scrollLeft;"
                        @"window.scrollBy(dx*amount,dy*amount);"
                        @"return (se.scrollTop!==bt||se.scrollLeft!==bl)?\"scrolled\":\"move\";"
                        @"})()",
                        (long)llround(point.x),
                        (long)llround(point.y),
                        (long)llround(direction.x),
                        (long)llround(direction.y),
                        (double)zone,
                        (double)amount];
    NSString *result = [webView stringByEvaluatingJavaScriptFromString:script];
    return [result isEqualToString:@"scrolled"];
}

- (NSDictionary *)navigationTargetFromDOMPoint:(CGPoint)point
                                     direction:(CGPoint)direction
                                   allowScroll:(BOOL)allowScroll
                                       webView:(BrowserWebView *)webView {
    if (webView == nil) {
        return nil;
    }
    NSString *script = [NSString stringWithFormat:
                        @"(function(){"
                        @"var x=%ld,y=%ld,dx=%ld,dy=%ld,allow=%ld;"
                        @"var sel=\"a[href],button,input:not([type='hidden']),textarea,select,summary,[role='button'],[role='link'],[role='tab'],[role='menuitem'],[role='option'],[onclick],[tabindex]:not([tabindex='-1'])\";"
                        @"var vw=window.innerWidth,vh=window.innerHeight;"
                        @"function okY(v){return v===\"auto\"||v===\"scroll\"||v===\"overlay\";}"
                        @"function okX(v){return okY(v)||v===\"hidden\";}"
                        @"function can(el){"
                        @"var cs=getComputedStyle(el);"
                        @"if(dy!==0&&okY(cs.overflowY)&&el.scrollHeight>el.clientHeight+1){"
                        @"if(dy>0&&el.scrollTop+el.clientHeight<el.scrollHeight-1){return true;}"
                        @"if(dy<0&&el.scrollTop>0){return true;}"
                        @"}"
                        @"if(dx!==0&&okX(cs.overflowX)&&el.scrollWidth>el.clientWidth+1){"
                        @"if(dx>0&&el.scrollLeft+el.clientWidth<el.scrollWidth-1){return true;}"
                        @"if(dx<0&&el.scrollLeft>0){return true;}"
                        @"}"
                        @"return false;"
                        @"}"
                        @"function findPanel(){"
                        @"var el=document.elementFromPoint(x,y);"
                        @"while(el&&el!==document.body&&el!==document.documentElement){"
                        @"if(can(el)){return el;}"
                        @"el=el.parentElement;"
                        @"}"
                        @"return null;"
                        @"}"
                        @"var prevEl=window.__navEl;"
                        @"var cur=prevEl;"
                        @"if(cur&&!cur.isConnected){cur=null;}"
                        @"var O=null;"
                        @"if(cur){var cr=cur.getBoundingClientRect();if(x>=cr.left-2&&x<=cr.right+2&&y>=cr.top-2&&y<=cr.bottom+2){O=cr;}else{cur=null;}}"
                        @"if(!O){O={left:x,right:x,top:y,bottom:y};}"
                        @"function clipped(el,rc){"
                        @"var p=el.parentElement;"
                        @"while(p&&p!==document.body&&p!==document.documentElement){"
                        @"var cs=getComputedStyle(p);"
                        @"if(cs.overflowX!==\"visible\"||cs.overflowY!==\"visible\"){"
                        @"var pr=p.getBoundingClientRect();"
                        @"if(rc.left<pr.left-1||rc.right>pr.right+1||rc.top<pr.top-1||rc.bottom>pr.bottom+1){return true;}"
                        @"}"
                        @"p=p.parentElement;"
                        @"}"
                        @"return false;"
                        @"}"
                        @"function inScrollArea(el,rc){"
                        @"var p=el.parentElement;"
                        @"while(p&&p!==document.body&&p!==document.documentElement){"
                        @"var cs=getComputedStyle(p);"
                        @"if(cs.overflowX!==\"visible\"||cs.overflowY!==\"visible\"){"
                        @"var pr=p.getBoundingClientRect();"
                        @"var rl=rc.left-pr.left+p.scrollLeft,rt=rc.top-pr.top+p.scrollTop;"
                        @"return rl>=-2&&rt>=-2&&rl+rc.width<=p.scrollWidth+2&&rt+rc.height<=p.scrollHeight+2;"
                        @"}"
                        @"p=p.parentElement;"
                        @"}"
                        @"var se=document.scrollingElement||document.documentElement;"
                        @"var dl=rc.left+se.scrollLeft,dt=rc.top+se.scrollTop;"
                        @"return dl>=-2&&dt>=-2&&dl+rc.width<=Math.max(se.scrollWidth,vw)+2&&dt+rc.height<=Math.max(se.scrollHeight,vh)+2;"
                        @"}"
                        @"function pick(){"
                        @"var nodes=document.querySelectorAll(sel),best=null,bestScore=1e12;"
                        @"for(var i=0;i<nodes.length;i++){"
                        @"var el=nodes[i];"
                        @"if(el===cur||el.disabled){continue;}"
                        @"var rc=el.getBoundingClientRect();"
                        @"if(rc.width<4||rc.height<4){continue;}"
                        @"if(rc.width*rc.height>0.6*vw*vh){continue;}"
                        @"var cs=getComputedStyle(el);"
                        @"if(cs.visibility===\"hidden\"||cs.display===\"none\"||parseFloat(cs.opacity)===0){continue;}"
                        @"var along,perp,off;"
                        @"if(dy!==0){"
                        @"along=dy>0?rc.top-O.bottom:O.top-rc.bottom;"
                        @"perp=Math.max(0,rc.left-O.right,O.left-rc.right);"
                        @"off=Math.abs((rc.left+rc.right)/2-(O.left+O.right)/2);"
                        @"}else{"
                        @"along=dx>0?rc.left-O.right:O.left-rc.right;"
                        @"perp=Math.max(0,rc.top-O.bottom,O.top-rc.bottom);"
                        @"off=Math.abs((rc.top+rc.bottom)/2-(O.top+O.bottom)/2);"
                        @"}"
                        @"if(along<-2){continue;}"
                        @"if(along<0){along=0;}"
                        @"var inside=rc.left>=0&&rc.top>=0&&rc.right<=vw&&rc.bottom<=vh&&!clipped(el,rc);"
                        @"if(inside){"
                        @"var hit=document.elementFromPoint((rc.left+rc.right)/2,(rc.top+rc.bottom)/2);"
                        @"if(!hit||!(el===hit||el.contains(hit)||hit.contains(el))){continue;}"
                        @"}else if(!inScrollArea(el,rc)){continue;}"
                        @"var score=along+perp*4+off*0.25;"
                        @"if(score<bestScore){bestScore=score;best={el:el,full:inside};}"
                        @"}"
                        @"return best;"
                        @"}"
                        @"function scrollStep(){"
                        @"var panel=findPanel();"
                        @"if(panel){"
                        @"var amt=(dy!==0?panel.clientHeight:panel.clientWidth)*0.6;"
                        @"var p1=panel.scrollTop,p2=panel.scrollLeft;"
                        @"panel.scrollTop+=dy*amt;panel.scrollLeft+=dx*amt;"
                        @"return panel.scrollTop!==p1||panel.scrollLeft!==p2;"
                        @"}"
                        @"var se=document.scrollingElement||document.documentElement;"
                        @"var b1=se.scrollTop,b2=se.scrollLeft;"
                        @"var amt2=(dy!==0?vh:vw)*0.6;"
                        @"window.scrollBy(dx*amt2,dy*amt2);"
                        @"return se.scrollTop!==b1||se.scrollLeft!==b2;"
                        @"}"
                        @"function reveal(el){"
                        @"try{el.scrollIntoView({block:\"center\",inline:\"nearest\",behavior:\"instant\"});return;}catch(e){}"
                        @"try{el.scrollIntoView({block:\"center\",inline:\"nearest\"});return;}catch(e2){}"
                        @"try{el.scrollIntoView();}catch(e3){}"
                        @"}"
                        @"function finish(el,didScroll){"
                        @"var rc=el.getBoundingClientRect();"
                        @"var l=Math.max(rc.left,0),t=Math.max(rc.top,0),r=Math.min(rc.right,vw),b=Math.min(rc.bottom,vh);"
                        @"if(r<=l||b<=t){l=Math.min(Math.max(rc.left,0),vw-2);r=l+1;t=Math.min(Math.max(rc.top,0),vh-2);b=t+1;}"
                        @"var cx=(l+r)/2,cy=(t+b)/2;"
                        @"if(prevEl&&prevEl!==el&&prevEl.isConnected){try{prevEl.dispatchEvent(new MouseEvent(\"mouseout\",{bubbles:true,cancelable:true,view:window}));prevEl.dispatchEvent(new MouseEvent(\"mouseleave\",{bubbles:false,view:window}));}catch(e){}}"
                        @"window.__navEl=el;"
                        @"try{[\"mouseover\",\"mouseenter\",\"mousemove\"].forEach(function(n){el.dispatchEvent(new MouseEvent(n,{bubbles:n!==\"mouseenter\",cancelable:true,view:window,clientX:cx,clientY:cy}));});}catch(e){}"
                        @"return JSON.stringify({found:true,x:cx,y:cy,scrolled:didScroll});"
                        @"}"
                        @"var best=pick();"
                        @"if(best){"
                        @"var did=false;"
                        @"if(!best.full){reveal(best.el);did=true;}"
                        @"return finish(best.el,did);"
                        @"}"
                        @"if(!allow){return JSON.stringify({found:false,x:0,y:0,scrolled:false});}"
                        @"var s=scrollStep();"
                        @"if(s){best=pick();if(best){return finish(best.el,true);}}"
                        @"return JSON.stringify({found:false,x:0,y:0,scrolled:s});"
                        @"})()",
                        (long)llround(point.x),
                        (long)llround(point.y),
                        (long)llround(direction.x),
                        (long)llround(direction.y),
                        (long)(allowScroll ? 1 : 0)];
    NSString *json = [webView stringByEvaluatingJavaScriptFromString:script];
    if (json.length == 0) {
        return nil;
    }
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    id object = data != nil ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    return [object isKindOfClass:[NSDictionary class]] ? object : nil;
}

- (NSString *)evaluateHoverStateJavaScriptAtPoint:(CGPoint)point
                                           webView:(BrowserWebView *)webView {
    if (webView == nil) {
        return @"false";
    }

    return [self evaluateResolvedElementJavaScriptAtPoint:point
                                                  webView:webView
                                                     body:@"var candidate = interactiveElement || resolvedElement;"
                                                          "while (candidate) {"
                                                              "if (candidate.matches && candidate.matches(interactiveSelector)) { return 'true'; }"
                                                              "candidate = candidate.parentElement;"
                                                          "}"
                                                          "return 'false';"];
}

- (NSString *)javaScriptEscapedString:(NSString *)string {
    NSString *escapedString = string ?: @"";
    escapedString = [escapedString stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    escapedString = [escapedString stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
    escapedString = [escapedString stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
    escapedString = [escapedString stringByReplacingOccurrencesOfString:@"\r" withString:@"\\r"];
    escapedString = [escapedString stringByReplacingOccurrencesOfString:@"\u2028" withString:@"\\u2028"];
    escapedString = [escapedString stringByReplacingOccurrencesOfString:@"\u2029" withString:@"\\u2029"];
    return escapedString;
}

- (NSDictionary *)videoInfoAtDOMPoint:(CGPoint)point
                               webView:(BrowserWebView *)webView {
    NSString *result = [self evaluateResolvedElementJavaScriptAtPoint:point
                                                               webView:webView
                                                                  body:@"function browserAbsoluteURL(url) {"
                                                                       "if (!url) { return ''; }"
                                                                       "try { return String(new URL(url, document.baseURI).toString()); } catch (error) { return String(url); }"
                                                                       "}"
                                                                       "function browserVideoContainsPoint(video) {"
                                                                           "if (!video || typeof video.getBoundingClientRect !== 'function') { return false; }"
                                                                           "var rect = video.getBoundingClientRect();"
                                                                           "return x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom;"
                                                                       "}"
                                                                       "function browserResolveVideoElement() {"
                                                                           "var candidate = resolvedElement;"
                                                                           "while (candidate) {"
                                                                               "if (candidate.tagName && candidate.tagName.toLowerCase() === 'video') { return candidate; }"
                                                                               "candidate = candidate.parentElement;"
                                                                           "}"
                                                                           "var videos = document.querySelectorAll('video');"
                                                                           "var bestVisibleVideo = null;"
                                                                           "var bestVisibleArea = 0;"
                                                                           "for (var i = 0; i < videos.length; i++) {"
                                                                               "var video = videos[i];"
                                                                               "if (browserVideoContainsPoint(video)) { return video; }"
                                                                               "if (!video || typeof video.getBoundingClientRect !== 'function') { continue; }"
                                                                               "var rect = video.getBoundingClientRect();"
                                                                               "var visibleWidth = Math.max(0, Math.min(rect.right, window.innerWidth) - Math.max(rect.left, 0));"
                                                                               "var visibleHeight = Math.max(0, Math.min(rect.bottom, window.innerHeight) - Math.max(rect.top, 0));"
                                                                               "var visibleArea = visibleWidth * visibleHeight;"
                                                                               "if (visibleArea <= 0) { continue; }"
                                                                               "if (!video.paused && !video.ended && video.readyState >= 2) { return video; }"
                                                                               "if (visibleArea > bestVisibleArea) {"
                                                                                   "bestVisibleArea = visibleArea;"
                                                                                   "bestVisibleVideo = video;"
                                                                               "}"
                                                                           "}"
                                                                           "return bestVisibleVideo;"
                                                                       "}"
                                                                       "function browserResolvePrimarySource(video) {"
                                                                           "if (!video) { return ''; }"
                                                                           "if (video.currentSrc) { return browserAbsoluteURL(video.currentSrc); }"
                                                                           "if (video.src) { return browserAbsoluteURL(video.src); }"
                                                                           "var sources = video.querySelectorAll('source');"
                                                                           "for (var i = 0; i < sources.length; i++) {"
                                                                               "var sourceSrc = sources[i].src || sources[i].getAttribute('src') || '';"
                                                                               "if (sourceSrc) { return browserAbsoluteURL(sourceSrc); }"
                                                                           "}"
                                                                           "return '';"
                                                                       "}"
                                                                       "function browserResolveSourceList(video) {"
                                                                           "var values = [];"
                                                                           "if (!video) { return values; }"
                                                                           "if (video.currentSrc) { values.push(browserAbsoluteURL(video.currentSrc)); }"
                                                                           "if (video.src && values.indexOf(browserAbsoluteURL(video.src)) === -1) { values.push(browserAbsoluteURL(video.src)); }"
                                                                           "var sources = video.querySelectorAll('source');"
                                                                           "for (var i = 0; i < sources.length; i++) {"
                                                                               "var sourceSrc = sources[i].src || sources[i].getAttribute('src') || '';"
                                                                               "sourceSrc = browserAbsoluteURL(sourceSrc);"
                                                                               "if (sourceSrc && values.indexOf(sourceSrc) === -1) { values.push(sourceSrc); }"
                                                                           "}"
                                                                           "return values;"
                                                                       "}"
                                                                       "var video = browserResolveVideoElement();"
                                                                       "if (!video) { return ''; }"
                                                                       "return JSON.stringify({"
                                                                           "src: browserResolvePrimarySource(video),"
                                                                           "sources: browserResolveSourceList(video),"
                                                                           "poster: browserAbsoluteURL(video.poster || ''),"
                                                                           "title: video.getAttribute('title') || video.getAttribute('aria-label') || document.title || '',"
                                                                           "tagName: video.tagName ? video.tagName.toLowerCase() : '',"
                                                                           "paused: !!video.paused"
                                                                       "});"];
    return [self JSONObjectFromJavaScriptString:result];
}

- (NSDictionary *)linkInfoAtDOMPoint:(CGPoint)point
                              webView:(BrowserWebView *)webView {
    NSString *result = [self evaluateResolvedElementJavaScriptAtPoint:point
                                                               webView:webView
                                                                  body:@"function browserAbsoluteURL(url) {"
                                                                       "if (!url) { return ''; }"
                                                                       "try { return String(new URL(url, document.baseURI).toString()); } catch (error) { return String(url); }"
                                                                       "}"
                                                                       "var element = interactiveElement || resolvedElement;"
                                                                       "if (!element) { return ''; }"
                                                                       "var link = null;"
                                                                       "if (element.closest) {"
                                                                           "link = element.closest('a[href]');"
                                                                       "}"
                                                                       "if (!link && element.tagName && element.tagName.toLowerCase() === 'a') {"
                                                                           "link = element;"
                                                                       "}"
                                                                       "if (!link) { return ''; }"
                                                                       "var href = link.href || (link.getAttribute ? (link.getAttribute('href') || '') : '');"
                                                                       "if (!href) { return ''; }"
                                                                       "var target = link.getAttribute ? (link.getAttribute('target') || '') : '';"
                                                                       "return JSON.stringify({"
                                                                           "href: browserAbsoluteURL(href),"
                                                                           "target: String(target || '').toLowerCase()"
                                                                       "});"];
    return [self JSONObjectFromJavaScriptString:result];
}

- (NSDictionary *)directVideoInfoAtDOMPoint:(CGPoint)point
                                     webView:(BrowserWebView *)webView {
    NSString *result = [self evaluateResolvedElementJavaScriptAtPoint:point
                                                               webView:webView
                                                                  body:@"function browserAbsoluteURL(url) {"
                                                                       "if (!url) { return ''; }"
                                                                       "try { return String(new URL(url, document.baseURI).toString()); } catch (error) { return String(url); }"
                                                                       "}"
                                                                       "function browserVideoContainsPoint(video) {"
                                                                           "if (!video || typeof video.getBoundingClientRect !== 'function') { return false; }"
                                                                           "var rect = video.getBoundingClientRect();"
                                                                           "return x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom;"
                                                                       "}"
                                                                       "function browserResolveDirectVideoElement() {"
                                                                           "var candidate = resolvedElement;"
                                                                           "while (candidate) {"
                                                                               "if (candidate.tagName && candidate.tagName.toLowerCase() === 'video') { return candidate; }"
                                                                               "candidate = candidate.parentElement;"
                                                                           "}"
                                                                           "var videos = document.querySelectorAll('video');"
                                                                           "for (var i = 0; i < videos.length; i++) {"
                                                                               "if (browserVideoContainsPoint(videos[i])) { return videos[i]; }"
                                                                           "}"
                                                                           "return null;"
                                                                       "}"
                                                                       "function browserResolvePrimarySource(video) {"
                                                                           "if (!video) { return ''; }"
                                                                           "if (video.currentSrc) { return browserAbsoluteURL(video.currentSrc); }"
                                                                           "if (video.src) { return browserAbsoluteURL(video.src); }"
                                                                           "var sources = video.querySelectorAll('source');"
                                                                           "for (var i = 0; i < sources.length; i++) {"
                                                                               "var sourceSrc = sources[i].src || sources[i].getAttribute('src') || '';"
                                                                               "if (sourceSrc) { return browserAbsoluteURL(sourceSrc); }"
                                                                           "}"
                                                                           "return '';"
                                                                       "}"
                                                                       "function browserResolveSourceList(video) {"
                                                                           "var values = [];"
                                                                           "if (!video) { return values; }"
                                                                           "if (video.currentSrc) { values.push(browserAbsoluteURL(video.currentSrc)); }"
                                                                           "if (video.src && values.indexOf(browserAbsoluteURL(video.src)) === -1) { values.push(browserAbsoluteURL(video.src)); }"
                                                                           "var sources = video.querySelectorAll('source');"
                                                                           "for (var i = 0; i < sources.length; i++) {"
                                                                               "var sourceSrc = sources[i].src || sources[i].getAttribute('src') || '';"
                                                                               "sourceSrc = browserAbsoluteURL(sourceSrc);"
                                                                               "if (sourceSrc && values.indexOf(sourceSrc) === -1) { values.push(sourceSrc); }"
                                                                           "}"
                                                                           "return values;"
                                                                       "}"
                                                                       "var video = browserResolveDirectVideoElement();"
                                                                       "if (!video) { return ''; }"
                                                                       "return JSON.stringify({"
                                                                           "src: browserResolvePrimarySource(video),"
                                                                           "sources: browserResolveSourceList(video),"
                                                                           "poster: browserAbsoluteURL(video.poster || ''),"
                                                                           "title: video.getAttribute('title') || video.getAttribute('aria-label') || document.title || '',"
                                                                           "tagName: video.tagName ? video.tagName.toLowerCase() : '',"
                                                                           "paused: !!video.paused"
                                                                       "});"];
    return [self JSONObjectFromJavaScriptString:result];
}

- (BOOL)isVideoActivationTargetAtDOMPoint:(CGPoint)point
                                   webView:(BrowserWebView *)webView {
    NSString *result = [self evaluateResolvedElementJavaScriptAtPoint:point
                                                               webView:webView
                                                                  body:@"function browserVideoContainsPoint(video) {"
                                                                       "if (!video || typeof video.getBoundingClientRect !== 'function') { return false; }"
                                                                       "var rect = video.getBoundingClientRect();"
                                                                       "return x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom;"
                                                                       "}"
                                                                       "function browserLooksLikeDismissControl(element) {"
                                                                           "if (!element) { return false; }"
                                                                           "var tagName = element.tagName ? element.tagName.toLowerCase() : '';"
                                                                           "var role = element.getAttribute ? (element.getAttribute('role') || '').toLowerCase() : '';"
                                                                           "var isButtonLike = tagName === 'button' || tagName === 'a' || role === 'button' ||"
                                                                               "(typeof element.onclick === 'function') ||"
                                                                               "(typeof element.tabIndex === 'number' && element.tabIndex >= 0);"
                                                                           "if (!isButtonLike) { return false; }"
                                                                           "var text = (element.textContent || '').replace(/\\s+/g, ' ').trim();"
                                                                           "var shortText = text.length <= 3 ? text : '';"
                                                                           "var label = ["
                                                                               "element.id || '',"
                                                                               "element.className || '',"
                                                                               "element.getAttribute ? (element.getAttribute('aria-label') || '') : '',"
                                                                               "element.getAttribute ? (element.getAttribute('title') || '') : '',"
                                                                               "element.getAttribute ? (element.getAttribute('name') || '') : '',"
                                                                               "shortText"
                                                                           "].join(' ').toLowerCase();"
                                                                           "if (!label) { return false; }"
                                                                           "if ((/(^|[^a-z])(close|dismiss|cancel|collapse|minimi[sz]e|exit)([^a-z]|$)/).test(label) ||"
                                                                               "label.indexOf('modal-close') !== -1 ||"
                                                                               "label.indexOf('icon-close') !== -1) {"
                                                                               "return true;"
                                                                           "}"
                                                                           "if (shortText === '×' || shortText === '✕' || shortText === '✖' || shortText === 'x' || shortText === 'X') {"
                                                                               "return true;"
                                                                           "}"
                                                                           "return false;"
                                                                       "}"
                                                                       "function browserMatchesVideoIntent(element) {"
                                                                           "if (!element) { return false; }"
                                                                           "if (browserLooksLikeDismissControl(element)) { return false; }"
                                                                           "var value = ["
                                                                               "element.id || '',"
                                                                               "element.className || '',"
                                                                               "element.getAttribute ? (element.getAttribute('role') || '') : '',"
                                                                               "element.getAttribute ? (element.getAttribute('aria-label') || '') : '',"
                                                                               "element.getAttribute ? (element.getAttribute('aria-description') || '') : '',"
                                                                               "element.getAttribute ? (element.getAttribute('title') || '') : ''"
                                                                           "].join(' ').toLowerCase();"
                                                                           "if (!value) { return false; }"
                                                                           "var hasPlayWord = (/(^|[^a-z])(play|watch|resume|trailer)([^a-z]|$)/).test(value);"
                                                                           "var hasControlWord = value.indexOf('ytp-') !== -1 || value.indexOf('video-play') !== -1 || value.indexOf('play-button') !== -1;"
                                                                           "return hasPlayWord || hasControlWord;"
                                                                       "}"
                                                                       "function browserContainsVideoAncestor(element) {"
                                                                           "var candidate = element;"
                                                                           "var depth = 0;"
                                                                           "while (candidate && depth < 10) {"
                                                                               "if (candidate.tagName && candidate.tagName.toLowerCase() === 'video') { return true; }"
                                                                               "candidate = candidate.parentElement;"
                                                                               "depth += 1;"
                                                                           "}"
                                                                           "return false;"
                                                                       "}"
                                                                       "function browserLooksLikeNavigationTarget(element) {"
                                                                           "if (!element) { return false; }"
                                                                           "var tagName = element.tagName ? element.tagName.toLowerCase() : '';"
                                                                           "if (tagName !== 'a' && tagName !== 'button') { return false; }"
                                                                           "if (element.closest && element.closest('nav, header, [role=\"navigation\"], .ac-gn, .ac-gn-content, .ac-gn-list, .globalnav')) { return true; }"
                                                                           "if (tagName === 'a') {"
                                                                               "var href = (element.getAttribute ? (element.getAttribute('href') || '') : '').trim().toLowerCase();"
                                                                               "if (href && href !== '#' && href.indexOf('javascript:') !== 0 && href.indexOf('mailto:') !== 0 && href.indexOf('tel:') !== 0) {"
                                                                                   "return true;"
                                                                               "}"
                                                                           "}"
                                                                           "return false;"
                                                                       "}"
                                                                       "if (browserLooksLikeNavigationTarget(interactiveElement) &&"
                                                                           "!browserContainsVideoAncestor(interactiveElement) &&"
                                                                           "!browserMatchesVideoIntent(interactiveElement)) {"
                                                                           "return 'false';"
                                                                       "}"
                                                                       "var candidate = resolvedElement;"
                                                                       "var candidateDepth = 0;"
                                                                       "while (candidate && candidateDepth < 10) {"
                                                                           "if (browserLooksLikeDismissControl(candidate)) { return 'false'; }"
                                                                           "if (candidate.tagName && candidate.tagName.toLowerCase() === 'video') { return 'true'; }"
                                                                           "if (browserMatchesVideoIntent(candidate)) { return 'true'; }"
                                                                           "candidate = candidate.parentElement;"
                                                                           "candidateDepth += 1;"
                                                                       "}"
                                                                       "var videos = document.querySelectorAll('video');"
                                                                       "for (var i = 0; i < videos.length; i++) {"
                                                                           "if (browserVideoContainsPoint(videos[i])) {"
                                                                               "if (browserLooksLikeNavigationTarget(interactiveElement) && !browserContainsVideoAncestor(interactiveElement)) { return 'false'; }"
                                                                               "if (browserLooksLikeDismissControl(interactiveElement) || browserLooksLikeDismissControl(resolvedElement)) { return 'false'; }"
                                                                               "return 'true';"
                                                                           "}"
                                                                       "}"
                                                                       "return 'false';"];
    return [result isEqualToString:@"true"];
}

- (BOOL)isVideoDismissTargetAtDOMPoint:(CGPoint)point
                                webView:(BrowserWebView *)webView {
    NSString *result = [self evaluateResolvedElementJavaScriptAtPoint:point
                                                               webView:webView
                                                                  body:@"function browserLooksLikeDismissControl(element) {"
                                                                       "if (!element) { return false; }"
                                                                       "var tagName = element.tagName ? element.tagName.toLowerCase() : '';"
                                                                       "var role = element.getAttribute ? (element.getAttribute('role') || '').toLowerCase() : '';"
                                                                       "var isButtonLike = tagName === 'button' || tagName === 'a' || role === 'button' ||"
                                                                           "(typeof element.onclick === 'function') ||"
                                                                           "(typeof element.tabIndex === 'number' && element.tabIndex >= 0);"
                                                                       "if (!isButtonLike) { return false; }"
                                                                       "var text = (element.textContent || '').replace(/\\s+/g, ' ').trim();"
                                                                       "var shortText = text.length <= 3 ? text : '';"
                                                                       "var label = ["
                                                                           "element.id || '',"
                                                                           "element.className || '',"
                                                                           "element.getAttribute ? (element.getAttribute('aria-label') || '') : '',"
                                                                           "element.getAttribute ? (element.getAttribute('title') || '') : '',"
                                                                           "element.getAttribute ? (element.getAttribute('name') || '') : '',"
                                                                           "shortText"
                                                                       "].join(' ').toLowerCase();"
                                                                       "if (!label) { return false; }"
                                                                       "if ((/(^|[^a-z])(close|dismiss|cancel|collapse|minimi[sz]e|exit)([^a-z]|$)/).test(label) ||"
                                                                           "label.indexOf('modal-close') !== -1 ||"
                                                                           "label.indexOf('icon-close') !== -1) {"
                                                                           "return true;"
                                                                       "}"
                                                                       "if (shortText === '×' || shortText === '✕' || shortText === '✖' || shortText === 'x' || shortText === 'X') {"
                                                                           "return true;"
                                                                       "}"
                                                                       "return false;"
                                                                   "}"
                                                                   "var candidate = interactiveElement || resolvedElement;"
                                                                   "while (candidate) {"
                                                                       "if (browserLooksLikeDismissControl(candidate)) { return 'true'; }"
                                                                       "candidate = candidate.parentElement;"
                                                                   "}"
                                                                   "return 'false';"];
    return [result isEqualToString:@"true"];
}

- (NSDictionary *)primedVideoInfoAtDOMPoint:(CGPoint)point
                                     webView:(BrowserWebView *)webView {
    [self evaluateResolvedElementJavaScriptAtPoint:point
                                           webView:webView
                                              body:@"window.__browserPrimedVideoInfo = '';"
                                                   "function browserAbsoluteURL(url) {"
                                                       "if (!url) { return ''; }"
                                                       "try { return String(new URL(url, document.baseURI).toString()); } catch (error) { return String(url); }"
                                                   "}"
                                                   "function browserVideoContainsPoint(video) {"
                                                       "if (!video || typeof video.getBoundingClientRect !== 'function') { return false; }"
                                                       "var rect = video.getBoundingClientRect();"
                                                       "return x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom;"
                                                   "}"
                                                   "function browserResolveVideoElement() {"
                                                       "var candidate = resolvedElement;"
                                                       "while (candidate) {"
                                                           "if (candidate.tagName && candidate.tagName.toLowerCase() === 'video') { return candidate; }"
                                                           "candidate = candidate.parentElement;"
                                                       "}"
                                                       "var videos = document.querySelectorAll('video');"
                                                       "var bestVisibleVideo = null;"
                                                       "var bestVisibleArea = 0;"
                                                       "for (var i = 0; i < videos.length; i++) {"
                                                           "var video = videos[i];"
                                                           "if (browserVideoContainsPoint(video)) { return video; }"
                                                           "if (!video || typeof video.getBoundingClientRect !== 'function') { continue; }"
                                                           "var rect = video.getBoundingClientRect();"
                                                           "var visibleWidth = Math.max(0, Math.min(rect.right, window.innerWidth) - Math.max(rect.left, 0));"
                                                           "var visibleHeight = Math.max(0, Math.min(rect.bottom, window.innerHeight) - Math.max(rect.top, 0));"
                                                           "var visibleArea = visibleWidth * visibleHeight;"
                                                           "if (visibleArea <= 0) { continue; }"
                                                           "if (!video.paused && !video.ended && video.readyState >= 2) { return video; }"
                                                           "if (visibleArea > bestVisibleArea) {"
                                                               "bestVisibleArea = visibleArea;"
                                                               "bestVisibleVideo = video;"
                                                           "}"
                                                       "}"
                                                       "return bestVisibleVideo;"
                                                   "}"
                                                   "function browserResolvePrimarySource(video) {"
                                                       "if (!video) { return ''; }"
                                                       "if (video.currentSrc) { return browserAbsoluteURL(video.currentSrc); }"
                                                       "if (video.src) { return browserAbsoluteURL(video.src); }"
                                                       "var sources = video.querySelectorAll('source');"
                                                       "for (var i = 0; i < sources.length; i++) {"
                                                           "var sourceSrc = sources[i].src || sources[i].getAttribute('src') || '';"
                                                           "if (sourceSrc) { return browserAbsoluteURL(sourceSrc); }"
                                                       "}"
                                                       "return '';"
                                                   "}"
                                                   "function browserResolveSourceList(video) {"
                                                       "var values = [];"
                                                       "if (!video) { return values; }"
                                                       "if (video.currentSrc) { values.push(browserAbsoluteURL(video.currentSrc)); }"
                                                       "if (video.src && values.indexOf(browserAbsoluteURL(video.src)) === -1) { values.push(browserAbsoluteURL(video.src)); }"
                                                       "var sources = video.querySelectorAll('source');"
                                                       "for (var i = 0; i < sources.length; i++) {"
                                                           "var sourceSrc = sources[i].src || sources[i].getAttribute('src') || '';"
                                                           "sourceSrc = browserAbsoluteURL(sourceSrc);"
                                                           "if (sourceSrc && values.indexOf(sourceSrc) === -1) { values.push(sourceSrc); }"
                                                       "}"
                                                       "return values;"
                                                   "}"
                                                   "function browserStoreVideoInfo(video) {"
                                                       "if (!video) { return; }"
                                                       "window.__browserPrimedVideoInfo = JSON.stringify({"
                                                           "src: browserResolvePrimarySource(video),"
                                                           "sources: browserResolveSourceList(video),"
                                                           "poster: browserAbsoluteURL(video.poster || ''),"
                                                           "title: video.getAttribute('title') || video.getAttribute('aria-label') || document.title || '',"
                                                           "tagName: video.tagName ? video.tagName.toLowerCase() : '',"
                                                           "paused: !!video.paused"
                                                       "});"
                                                   "}"
                                                   "var video = browserResolveVideoElement();"
                                                   "if (!video) { return 'no-video'; }"
                                                   "try { if (video.focus) { video.focus(); } } catch (error) {}"
                                                   "var finish = function() {"
                                                       "try { if (video.pause) { video.pause(); } } catch (error) {}"
                                                       "browserStoreVideoInfo(video);"
                                                   "};"
                                                   "try {"
                                                       "var playResult = video.play ? video.play() : null;"
                                                       "if (playResult && typeof playResult.then === 'function') {"
                                                           "playResult.then(function() { setTimeout(finish, 0); }).catch(function() { setTimeout(finish, 0); });"
                                                       "} else {"
                                                           "setTimeout(finish, 0);"
                                                       "}"
                                                   "} catch (error) {"
                                                       "setTimeout(finish, 0);"
                                                   "}"
                                                   "return 'started';"];

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:0.75];
    while ([deadline timeIntervalSinceNow] > 0) {
        NSString *result = [webView stringByEvaluatingJavaScriptFromString:@"window.__browserPrimedVideoInfo || ''"];
        NSDictionary *videoInfo = [self JSONObjectFromJavaScriptString:result];
        if (videoInfo.count > 0) {
            return videoInfo;
        }
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    }

    return nil;
}

- (NSDictionary *)activateVideoTargetAtDOMPoint:(CGPoint)point
                                         webView:(BrowserWebView *)webView
                                         timeout:(NSTimeInterval)timeout {
    if (webView == nil) {
        return nil;
    }

    NSTimeInterval effectiveTimeout = timeout > 0.0 ? timeout : 1.5;
    [self evaluateResolvedElementJavaScriptAtPoint:point
                                           webView:webView
                                              body:@"function browserMatchesVideoIntent(element) {"
                                                   "if (!element) { return false; }"
                                                   "if (browserLooksLikeDismissControl(element)) { return false; }"
                                                   "var value = ["
                                                       "element.id || '',"
                                                       "element.className || '',"
                                                       "element.getAttribute ? (element.getAttribute('role') || '') : '',"
                                                       "element.getAttribute ? (element.getAttribute('aria-label') || '') : '',"
                                                       "element.getAttribute ? (element.getAttribute('aria-description') || '') : '',"
                                                       "element.getAttribute ? (element.getAttribute('title') || '') : ''"
                                                   "].join(' ').toLowerCase();"
                                                   "if (!value) { return false; }"
                                                   "var hasPlayWord = (/(^|[^a-z])(play|watch|resume|trailer)([^a-z]|$)/).test(value);"
                                                   "var hasControlWord = value.indexOf('ytp-') !== -1 || value.indexOf('video-play') !== -1 || value.indexOf('play-button') !== -1;"
                                                   "return hasPlayWord || hasControlWord;"
                                               "}"
                                               "function browserLooksLikeDismissControl(element) {"
                                                   "if (!element) { return false; }"
                                                   "var tagName = element.tagName ? element.tagName.toLowerCase() : '';"
                                                   "var role = element.getAttribute ? (element.getAttribute('role') || '').toLowerCase() : '';"
                                                   "var isButtonLike = tagName === 'button' || tagName === 'a' || role === 'button' ||"
                                                       "(typeof element.onclick === 'function') ||"
                                                       "(typeof element.tabIndex === 'number' && element.tabIndex >= 0);"
                                                   "if (!isButtonLike) { return false; }"
                                                   "var text = (element.textContent || '').replace(/\\s+/g, ' ').trim();"
                                                   "var shortText = text.length <= 3 ? text : '';"
                                                   "var label = ["
                                                       "element.id || '',"
                                                       "element.className || '',"
                                                       "element.getAttribute ? (element.getAttribute('aria-label') || '') : '',"
                                                       "element.getAttribute ? (element.getAttribute('title') || '') : '',"
                                                       "element.getAttribute ? (element.getAttribute('name') || '') : '',"
                                                       "shortText"
                                                   "].join(' ').toLowerCase();"
                                                   "if (!label) { return false; }"
                                                   "if ((/(^|[^a-z])(close|dismiss|cancel|collapse|minimi[sz]e|exit)([^a-z]|$)/).test(label) ||"
                                                       "label.indexOf('modal-close') !== -1 ||"
                                                       "label.indexOf('icon-close') !== -1) {"
                                                       "return true;"
                                                   "}"
                                                   "if (shortText === '×' || shortText === '✕' || shortText === '✖' || shortText === 'x' || shortText === 'X') {"
                                                       "return true;"
                                                   "}"
                                                   "return false;"
                                               "}"
                                               "function browserActivationTarget() {"
                                                   "function browserContainsVideoAncestor(element) {"
                                                       "var candidate = element;"
                                                       "var depth = 0;"
                                                       "while (candidate && depth < 10) {"
                                                           "if (candidate.tagName && candidate.tagName.toLowerCase() === 'video') { return true; }"
                                                           "candidate = candidate.parentElement;"
                                                           "depth += 1;"
                                                       "}"
                                                       "return false;"
                                                   "}"
                                                   "function browserLooksLikeNavigationTarget(element) {"
                                                       "if (!element) { return false; }"
                                                       "var tagName = element.tagName ? element.tagName.toLowerCase() : '';"
                                                       "if (tagName !== 'a' && tagName !== 'button') { return false; }"
                                                       "if (element.closest && element.closest('nav, header, [role=\"navigation\"], .ac-gn, .ac-gn-content, .ac-gn-list, .globalnav')) { return true; }"
                                                       "if (tagName === 'a') {"
                                                           "var href = (element.getAttribute ? (element.getAttribute('href') || '') : '').trim().toLowerCase();"
                                                           "if (href && href !== '#' && href.indexOf('javascript:') !== 0 && href.indexOf('mailto:') !== 0 && href.indexOf('tel:') !== 0) {"
                                                               "return true;"
                                                           "}"
                                                       "}"
                                                       "return false;"
                                                   "}"
                                                   "var candidate = interactiveElement || resolvedElement;"
                                                   "if (browserLooksLikeNavigationTarget(candidate) &&"
                                                       "!browserContainsVideoAncestor(candidate) &&"
                                                       "!browserMatchesVideoIntent(candidate)) {"
                                                       "return null;"
                                                   "}"
                                                   "var depth = 0;"
                                                   "while (candidate && depth < 10) {"
                                                       "if (browserLooksLikeDismissControl(candidate)) { return null; }"
                                                       "if (candidate.tagName && candidate.tagName.toLowerCase() === 'video') { return candidate; }"
                                                       "if (browserMatchesVideoIntent(candidate)) { return candidate; }"
                                                       "candidate = candidate.parentElement;"
                                                       "depth += 1;"
                                                   "}"
                                                   "return interactiveElement || resolvedElement || null;"
                                               "}"
                                               "function dispatchPointerLikeEvent(target, type, constructorName) {"
                                                   "if (!target) { return; }"
                                                   "try {"
                                                       "var Constructor = window[constructorName];"
                                                       "if (Constructor) {"
                                                           "var event = new Constructor(type, { bubbles: true, cancelable: true, composed: true, view: window, clientX: x, clientY: y, screenX: x, screenY: y, button: 0, buttons: 1, pointerType: 'mouse' });"
                                                           "target.dispatchEvent(event);"
                                                           "return;"
                                                       "}"
                                                   "} catch (error) {}"
                                                   "var mouseEvent = document.createEvent('MouseEvents');"
                                                   "mouseEvent.initMouseEvent(type, true, true, window, 1, x, y, x, y, false, false, false, false, 0, null);"
                                                   "target.dispatchEvent(mouseEvent);"
                                               "}"
                                               "var target = browserActivationTarget();"
                                               "if (!target) { return 'no-target'; }"
                                               "try { if (target.focus) { target.focus(); } } catch (error) {}"
                                               "dispatchPointerLikeEvent(target, 'pointerdown', 'PointerEvent');"
                                               "dispatchPointerLikeEvent(target, 'mousedown', 'MouseEvent');"
                                               "dispatchPointerLikeEvent(target, 'pointerup', 'PointerEvent');"
                                               "dispatchPointerLikeEvent(target, 'mouseup', 'MouseEvent');"
                                               "if (typeof target.click === 'function') { target.click(); }"
                                               "else { dispatchPointerLikeEvent(target, 'click', 'MouseEvent'); }"
                                               "return 'clicked';"];

    NSDictionary *lastVideoInfo = nil;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:effectiveTimeout];
    while ([deadline timeIntervalSinceNow] > 0) {
        NSDictionary *directVideoInfo = [self directVideoInfoAtDOMPoint:point webView:webView];
        NSString *directSrc = [directVideoInfo[@"src"] isKindOfClass:[NSString class]] ? directVideoInfo[@"src"] : @"";
        NSArray *directSources = [directVideoInfo[@"sources"] isKindOfClass:[NSArray class]] ? directVideoInfo[@"sources"] : @[];
        if (directSrc.length > 0 || directSources.count > 0) {
            return directVideoInfo;
        }

        NSDictionary *videoInfo = [self videoInfoAtDOMPoint:point webView:webView];
        if (videoInfo.count > 0) {
            lastVideoInfo = videoInfo;
            NSString *videoSrc = [videoInfo[@"src"] isKindOfClass:[NSString class]] ? videoInfo[@"src"] : @"";
            NSArray *videoSources = [videoInfo[@"sources"] isKindOfClass:[NSArray class]] ? videoInfo[@"sources"] : @[];
            if (videoSrc.length > 0 || videoSources.count > 0) {
                return videoInfo;
            }
        }

        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }

    return lastVideoInfo;
}

- (NSDictionary *)JSONObjectFromJavaScriptString:(NSString *)string {
    if (string.length == 0) {
        return nil;
    }

    NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
    if (data == nil) {
        return nil;
    }

    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![object isKindOfClass:[NSDictionary class]]) {
        return nil;
    }

    return object;
}

@end
