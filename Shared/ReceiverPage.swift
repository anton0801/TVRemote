import Foundation

/// Receiver web page opened in the TV's built-in browser. Served by the broadcast extension
/// from the phone itself (no external website). Plain ES5 so older TV browsers run it.
///
/// It connects back with the session token as WebSocket subprotocol, draws JPEG frames, and
/// acknowledges each *displayed* frame — that acknowledgement is what the app treats as
/// "the TV really shows the screen" (diagnostic timer, analytics, latency).
enum ReceiverPage {
    struct Strings {
        let connecting: String
        let waiting: String
        let ended: String
        let testEnded: String
        let lost: String
    }

    static func strings(for language: String) -> Strings {
        switch language {
        case "es": Strings(connecting: "Conectando con el iPhone…", waiting: "Esperando la imagen del iPhone…",
                           ended: "La duplicación ha terminado.", testEnded: "La prueba gratuita ha terminado. Continúa en el iPhone.",
                           lost: "Se perdió la conexión con el iPhone.")
        case "ru": Strings(connecting: "Подключение к iPhone…", waiting: "Ожидание изображения с iPhone…",
                           ended: "Трансляция завершена.", testEnded: "Бесплатная проверка завершена. Продолжите на iPhone.",
                           lost: "Связь с iPhone потеряна.")
        case "de": Strings(connecting: "Verbindung zum iPhone wird hergestellt …", waiting: "Warten auf das Bild vom iPhone …",
                           ended: "Die Spiegelung wurde beendet.", testEnded: "Der kostenlose Test ist beendet. Fahre auf dem iPhone fort.",
                           lost: "Die Verbindung zum iPhone wurde getrennt.")
        case "fr": Strings(connecting: "Connexion à l’iPhone…", waiting: "En attente de l’image de l’iPhone…",
                           ended: "La recopie est terminée.", testEnded: "Le test gratuit est terminé. Continuez sur l’iPhone.",
                           lost: "La connexion avec l’iPhone a été perdue.")
        default: Strings(connecting: "Connecting to iPhone…", waiting: "Waiting for the iPhone screen…",
                         ended: "Mirroring has ended.", testEnded: "The free test has ended. Continue on your iPhone.",
                         lost: "Connection to the iPhone was lost.")
        }
    }

    static func html(webSocketPort: UInt16, token: String, language: String) -> String {
        let s = strings(for: language)
        func js(_ value: String) -> String {
            value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        return """
        <!DOCTYPE html>
        <html lang="\(language)"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>TV Remote</title>
        <style>
        html,body{margin:0;height:100%;background:#000;overflow:hidden;font-family:sans-serif;color:#F5F6F8}
        #f{position:absolute;top:0;left:0;width:100%;height:100%;object-fit:contain;display:none}
        #m{position:absolute;top:50%;left:0;right:0;transform:translateY(-50%);text-align:center;font-size:32px;padding:0 10%}
        </style></head>
        <body><img id="f" alt=""><div id="m">\(s.connecting)</div>
        <script>
        (function(){
          var img=document.getElementById("f"), msg=document.getElementById("m");
          var host=location.hostname, prev=null, ended=false, pending=null, busy=false;
          var T={waiting:"\(js(s.waiting))",ended:"\(js(s.ended))",testEnded:"\(js(s.testEnded))",lost:"\(js(s.lost))"};
          function show(t){msg.innerHTML="";msg.appendChild(document.createTextNode(t));msg.style.display="block";img.style.display="none";}
          var ws;
          try{ws=new WebSocket("ws://"+host+":\(webSocketPort)/","t\(token)");}catch(e){show(T.lost);return;}
          ws.binaryType="arraybuffer";
          ws.onopen=function(){show(T.waiting);};
          function draw(buf){
            busy=true;
            var v=new DataView(buf), turns=v.getUint8(1), seq=v.getUint32(2), ts=v.getUint32(6);
            var blob=new Blob([new Uint8Array(buf,10)],{type:"image/jpeg"});
            var url=(window.URL||window.webkitURL).createObjectURL(blob);
            img.onload=function(){
              if(prev){(window.URL||window.webkitURL).revokeObjectURL(prev);}
              prev=url; msg.style.display="none"; img.style.display="block";
              var r=turns*90; img.style.transform=r?"rotate("+r+"deg)":"";
              if(ws.readyState===1){ws.send("a:"+seq+":"+ts);}
              busy=false; if(pending){var p=pending;pending=null;draw(p);}
            };
            img.onerror=function(){busy=false;(window.URL||window.webkitURL).revokeObjectURL(url);};
            img.src=url;
          }
          ws.onmessage=function(e){
            if(typeof e.data==="string"){
              if(e.data.indexOf("end:")===0){ended=true;show(e.data==="end:test"?T.testEnded:T.ended);}
              return;
            }
            if(busy){pending=e.data;return;}
            draw(e.data);
          };
          ws.onclose=function(){if(!ended){show(T.lost);}};
        })();
        </script></body></html>
        """
    }
}
