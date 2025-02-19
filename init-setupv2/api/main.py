from flask import Flask, request, jsonify, abort
from flask_sqlalchemy import SQLAlchemy
import random
import string
from sqlalchemy import func

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

if __name__ == '__main__':
    app.run(debug=True, host='0.0.0.0')
