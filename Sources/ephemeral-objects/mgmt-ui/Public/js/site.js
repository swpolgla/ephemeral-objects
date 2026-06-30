(() => {
    const body = document.body;
    const page = body.dataset.page;
    const activeNav = document.querySelector(`[data-nav="${page}"]`);
    if (activeNav) activeNav.setAttribute("aria-current", "page");

    const uploader = document.querySelector("[data-uploader]");
    if (!uploader) return;

    const input = uploader.querySelector("[data-file-input]");
    const dropZone = uploader.querySelector("[data-drop-zone]");
    const status = uploader.querySelector("[data-status]");
    const states = [...uploader.querySelectorAll("[data-state]")];
    const fileName = uploader.querySelector("[data-file-name]");
    const fileSize = uploader.querySelector("[data-file-size]");
    const progressBar = uploader.querySelector("[data-progress-bar]");
    const progressLabel = uploader.querySelector("[data-progress-label]");
    const shareLink = uploader.querySelector("[data-share-link]");
    const copyButton = uploader.querySelector("[data-copy-link]");
    const resetButtons = [...uploader.querySelectorAll("[data-reset]")];
    let activeRequest;

    const showState = (name) => {
        states.forEach((state) => {
            state.hidden = state.dataset.state !== name;
        });
    };

    const formatSize = (bytes) => {
        if (bytes === 0) return "0 bytes";
        const units = ["bytes", "KB", "MB", "GB"];
        const unit = Math.min(Math.floor(Math.log(bytes) / Math.log(1024)), units.length - 1);
        return `${(bytes / Math.pow(1024, unit)).toFixed(unit ? 1 : 0)} ${units[unit]}`;
    };

    const responseDownloadURL = (request) => {
        const contentType = request.getResponseHeader("content-type") || "";
        const responseText = request.responseText.trim();
        let payload;

        if (contentType.includes("application/json")) {
            try {
                payload = JSON.parse(responseText);
            } catch {
                return null;
            }

            const directURL = payload.downloadURL
                || payload.downloadUrl
                || payload.url
                || payload.link;
            if (directURL) return new URL(directURL, window.location.origin).href;

            const identifier = payload.hash || payload.id;
            if (identifier) {
                return new URL(`/files/${encodeURIComponent(identifier)}`, window.location.origin).href;
            }
            return null;
        }

        if (/^(https?:\/\/|\/)/i.test(responseText)) {
            return new URL(responseText, window.location.origin).href;
        }
        if (/^[a-z0-9_-]{8,}$/i.test(responseText) && responseText !== "FILES POST") {
            return new URL(`/files/${encodeURIComponent(responseText)}`, window.location.origin).href;
        }
        return null;
    };

    const uploadFile = (file) => {
        status.textContent = "";
        if (!file || file.size === 0) {
            status.textContent = "Choose a file with some content to continue.";
            return;
        }
        if (file.size > 1024 * 1024 * 1024) {
            status.textContent = "That file is larger than the 1 GB prototype limit.";
            return;
        }

        fileName.textContent = file.name;
        fileSize.textContent = formatSize(file.size);
        progressBar.style.width = "0%";
        showState("progress");
        progressLabel.textContent = "Uploading… 0%";
        status.textContent = `Uploading ${file.name}.`;

        activeRequest = new XMLHttpRequest();
        activeRequest.open("POST", "/files");
        activeRequest.setRequestHeader("Accept", "application/json, text/plain");
        activeRequest.setRequestHeader("Content-Type", file.type || "application/octet-stream");
        activeRequest.setRequestHeader("X-File-Name", encodeURIComponent(file.name));
        activeRequest.setRequestHeader("X-File-Size", String(file.size));

        activeRequest.upload.addEventListener("progress", (event) => {
            if (!event.lengthComputable) return;
            const progress = Math.round((event.loaded / event.total) * 100);
            progressBar.style.width = `${progress}%`;
            progressLabel.textContent = `Uploading… ${progress}%`;
        });

        activeRequest.addEventListener("load", () => {
            progressBar.style.width = "100%";
            if (activeRequest.status >= 200 && activeRequest.status < 300) {
                const downloadURL = responseDownloadURL(activeRequest);
                if (!downloadURL) {
                    showState("accepted");
                    status.textContent = "Upload accepted, but the server did not return a download link.";
                    resetButtons[1].focus();
                    activeRequest = null;
                    return;
                }

                shareLink.value = downloadURL;
                showState("complete");
                status.textContent = "Upload complete. Download link ready.";
                copyButton.focus();
            } else {
                showState("idle");
                status.textContent = `Upload failed with status ${activeRequest.status}. Please try again.`;
            }
            activeRequest = null;
        });

        activeRequest.addEventListener("error", () => {
            showState("idle");
            status.textContent = "The upload could not reach the server. Please try again.";
            activeRequest = null;
        });

        activeRequest.addEventListener("abort", () => {
            showState("idle");
            status.textContent = "Upload cancelled.";
            activeRequest = null;
        });

        activeRequest.send(file);
    };

    input.addEventListener("change", () => uploadFile(input.files[0]));

    ["dragenter", "dragover"].forEach((eventName) => {
        dropZone.addEventListener(eventName, (event) => {
            event.preventDefault();
            dropZone.classList.add("is-dragging");
        });
    });

    ["dragleave", "drop"].forEach((eventName) => {
        dropZone.addEventListener(eventName, (event) => {
            event.preventDefault();
            dropZone.classList.remove("is-dragging");
        });
    });

    dropZone.addEventListener("drop", (event) => uploadFile(event.dataTransfer.files[0]));

    copyButton.addEventListener("click", async () => {
        try {
            await navigator.clipboard.writeText(shareLink.value);
        } catch {
            shareLink.select();
            document.execCommand("copy");
        }
        copyButton.textContent = "Copied!";
        status.textContent = "Download link copied to clipboard.";
        window.setTimeout(() => { copyButton.textContent = "Copy link"; }, 1800);
    });

    resetButtons.forEach((button) => {
        button.addEventListener("click", () => {
            if (activeRequest) activeRequest.abort();
            input.value = "";
            shareLink.value = "";
            copyButton.textContent = "Copy link";
            status.textContent = "";
            showState("idle");
            input.focus();
        });
    });
})();
