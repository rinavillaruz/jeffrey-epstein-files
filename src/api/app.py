from flask import Flask

app = Flask(__name__)

@app.route("/")
@app.route("/health")
def hello():
    return "Hello World"