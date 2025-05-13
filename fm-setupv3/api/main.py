from flask import Flask, request, jsonify, abort
from flask_sqlalchemy import SQLAlchemy
import random
import string
from sqlalchemy import func
from PIL import Image, ImageDraw, ImageFont
from brother_ql.conversion import convert
from brother_ql.backends.helpers import send
from brother_ql.raster import BrotherQLRaster

app = Flask(__name__)
app.config['SQLALCHEMY_DATABASE_URI'] = 'sqlite:///prod.db'
db = SQLAlchemy(app)

class fm(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    hostname = db.Column(db.String(80), nullable=False)
    adminUserName = db.Column(db.String(20), nullable=True)
    adminUserPw = db.Column(db.String(40), nullable=True)
    setup_ready = db.Column(db.Boolean, default=False)

with app.app_context():
    db.create_all()

@app.route('/')
def hello_world():
    return 'This is the FusionMiner Setup API!'

@app.route('/api/v2/fm/generate-hostname', methods=['POST'])
def generate_hostname():
    data = request.get_json()
    num = data.get('fm-model')
    if not num:
        abort(400, description="Missing 'fm-model'")
    next_id = db.session.query(func.max(fm.id)).scalar() or 0
    new_id = next_id + 1
    result_hostname = f"FM-{num}-{new_id + 100:06d}".lstrip('0')
    entry = fm(hostname=result_hostname, adminUserName="", adminUserPw="")
    db.session.add(entry)
    db.session.commit()
    return jsonify({"hostname": result_hostname, "id": entry.id})

@app.route('/api/v2/fm/delete', methods=['POST'])
def delete_fm():
    data = request.get_json()
    hostname = data.get('hostname')
    if not hostname:
        abort(400, description="Missing 'hostname'")
    entry = fm.query.filter_by(hostname=hostname).first()
    if entry is None:
        abort(404, description="Hostname not found")
    db.session.delete(entry)
    db.session.commit()
    return jsonify({'message': 'Entry deleted successfully'})

@app.route('/api/v2/fm/update', methods=['POST'])
def update_fm():
    data = request.get_json()
    hostname = data.get('hostname')
    adminUserName = data.get('adminUserName')
    adminUserPw = data.get('adminUserPw')

    if not hostname or not adminUserName or not adminUserPw:
        abort(400, description="Missing required fields")

    entry = fm.query.filter_by(hostname=hostname).first()
    if entry is None:
        abort(404, description="Hostname not found")

    entry.adminUserName = adminUserName
    entry.adminUserPw = adminUserPw
    db.session.commit()

    return jsonify({'message': 'Entry updated successfully'})

@app.route('/api/v2/fm/status', methods=['POST'])
def update_status():
    data = request.get_json()
    hostname = data.get('hostname')
    setup_ready = data.get('setup_ready')

    if not hostname or setup_ready is None:
        abort(400, description="Missing required fields")

    entry = fm.query.filter_by(hostname=hostname).first()
    if entry is None:
        abort(404, description="Hostname not found")

    entry.setup_ready = setup_ready
    db.session.commit()

    return jsonify({'message': 'Status updated successfully'})

@app.route('/api/v2/fm/showall', methods=['GET'])
def show_all():
    entries = fm.query.all()
    return jsonify([{"hostname": entry.hostname, "adminUserName": entry.adminUserName, "adminUserPw": entry.adminUserPw, "setup_ready": entry.setup_ready} for entry in entries])

@app.route('/api/v2/fm/print-label', methods=['POST'])
def print_label():
    data = request.get_json()
    hostname = data.get('hostname')
    setup_code = data.get('setup_code')
    
    if not hostname:
        abort(400, description="Missing 'hostname'")
    if not setup_code:
        abort(400, description="Missing 'setup_code'")
    
    entry = fm.query.filter_by(hostname=hostname).first()
    if entry is None:
        abort(404, description="Hostname not found")
    
    try:
        # Fix zur ANTIALIAS-Deprecation (Pillow ≥ 10)
        if not hasattr(Image, 'ANTIALIAS'):
            try:
                Image.ANTIALIAS = Image.Resampling.LANCZOS
            except AttributeError:
                Image.ANTIALIAS = Image.LANCZOS


        DPI = 300
        WIDTH_MM, HEIGHT_MM = 62, 25  # Höhe um 5 mm reduziert
        MARGIN_MM = 1  # kleinere Ränder
        
        OUTPUT_FILE = f"label_{hostname}.png"
        
        # Drucker-Konfiguration (WLAN)
        MODEL = 'QL-810W'                 # Druckermodell
        PRINTER_IDENTIFIER = 'BRW60E9AAEBAE71'  # Netzwerkname des Druckers
        BACKEND_IDENTIFIER = 'network'

        px = lambda mm: int(mm * 0.4 * DPI)
        
        # ---------- Canvas ----------
        img = Image.new("RGB", (px(WIDTH_MM), px(HEIGHT_MM)), "white")
        draw = ImageDraw.Draw(img)
        
        # Hilfsfunktion zur größtmöglichen Font
        def best_font(lines, area_w, area_h, bold=False, start_pt=40):
            pt = start_pt
            while pt > 6:
                f = ImageFont.truetype(
                    "DejaVuSans%s.ttf" % ("-Bold" if bold else ""), int(pt * 0.4)
                )
                w = max(draw.textbbox((0,0), t, font=f)[2] for t in lines)
                h = sum(draw.textbbox((0,0), t, font=f)[3] for t in lines)
                if w <= area_w and h <= area_h:
                    return f
                pt -= 1
            return f
        
        # ---------- Header (zentriert) ----------
        header_text = "FusionMiner"
        hdr_area = (px(WIDTH_MM) - 2*px(MARGIN_MM), px(8))
        font_hdr = best_font([header_text], hdr_area[0], hdr_area[1], bold=True, start_pt=36)
        
        hdr_w = draw.textbbox((0,0), header_text, font=font_hdr)[2]
        hdr_x = (px(WIDTH_MM) - hdr_w) // 2
        y = px(MARGIN_MM)
        draw.text((hdr_x, y), header_text, font=font_hdr, fill="black")
        y += font_hdr.getbbox(header_text)[3] + px(1)
        
        # ---------- Faktenblock (zentriert) ----------
        body_lines = [f"ID: {hostname}", f"Setup-Code: {setup_code}"]
        remaining_h = px(HEIGHT_MM) - y - px(MARGIN_MM)
        font_body = best_font(body_lines, px(WIDTH_MM) - 2*px(MARGIN_MM), remaining_h, start_pt=28)
        
        for line in body_lines:
            w = draw.textbbox((0,0), line, font=font_body)[2]
            x = (px(WIDTH_MM) - w) // 2
            draw.text((x, y), line, font=font_body, fill="black")
            y += font_body.getbbox(line)[3]
        
        # ---------- Ausgabe der Grafik ----------
        img.save(OUTPUT_FILE, dpi=(DPI, DPI))
        
        # ---------- Drucken über WLAN ----------
        qlr = BrotherQLRaster(MODEL)
        qlr.exception_on_warning = True
        
        instructions = convert(
            qlr=qlr,
            images=[img],
            label='62',       # 62mm Endlosband
            rotate='0',       # keine Rotation
            threshold=70.0,   # Schwarz-Weiß-Schwelle
            dither=False,
            compress=False,
            dpi_600=False,
            hq=True,
            cut=True,
            red=True         # 2-Farb-Band: Schwarz/Rot auf Weiß
        )
        
        send(
            instructions=instructions,
            printer_identifier=PRINTER_IDENTIFIER,
            backend_identifier=BACKEND_IDENTIFIER
        )
        
        return jsonify({'message': f'Label für {hostname} erstellt und gedruckt'})
    
    except Exception as e:
        return jsonify({'error': str(e)}), 500

    

    

if __name__ == '__main__':
    app.run(debug=True, host='0.0.0.0')
