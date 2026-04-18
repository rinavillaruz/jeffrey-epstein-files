import requests
import os
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from requests.exceptions import ConnectionError, Timeout

cookies = {
    "justiceGovAgeVerified" : "true"
}

dataset = {"number": 1, "start": 1, "end": 650}

pod_index   = int(os.environ.get("JOB_COMPLETION_INDEX", 0))
workers     = int(os.environ.get("WORKERS", 25))
total_pods  = int(os.environ.get("TOTAL_PODS", 4))

total_files = dataset["end"] - dataset["start"]
chunk_size  = total_files // total_pods

start = dataset["start"] + (pod_index * chunk_size)
end   = start + chunk_size if pod_index < total_pods - 1 else dataset["end"]

print(f"Pod {pod_index}: downloading dataset {dataset['number']} from {start} to {end}")

os.makedirs(f"/data/dataset-{dataset['number']}", exist_ok=True)

def download_file(url, filename):
   if os.path.exists(filename):
      return f"SKIP {filename}"
  
   retries = 3

   for attempt in range(retries):
       try:
           response = requests.get(url, cookies=cookies, timeout=30)

           if response.status_code == 200:
               with open(filename, "wb") as f:
                   f.write(response.content)
                   return f"OK {filename}"
           elif response.status_code == 403:
               return f"BLOCKED {url}"
           elif response.status_code == 429:
               time.sleep(10)
               continue
           else:
               return f"FAIL {url} - {response.status_code}"
       except (ConnectionError, Timeout):
           if attempt < retries - 1:
               time.sleep(5)
           else:
               return f"NETWORK_ERROR {url}"

tasks = []
for file_number in range(start, end + 1):
   url = f"https://www.justice.gov/epstein/files/DataSet%20{dataset['number']}/EFTA{file_number:08d}.pdf"
   filename = f"/data/dataset-{dataset['number']}/EFTA{file_number:08d}.pdf"
   tasks.append((url, filename))

total = len(tasks)
completed = 0

with ThreadPoolExecutor(max_workers=workers) as executor:
    futures = {executor.submit(download_file, url, fname) : fname for url, fname in tasks}
    for future in as_completed(futures):
        result = future.result()
        completed += 1

        print(f"[{completed}/{total} {result}]")

print(f"\nPod {pod_index} done!")
