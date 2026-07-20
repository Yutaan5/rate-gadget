ObjC.import("Foundation");

function numberOrNull(value) {
    return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function windowSnapshot(value) {
    if (!value || numberOrNull(value.used_percentage) === null) {
        return null;
    }
    return {
        used_percentage: numberOrNull(value.used_percentage),
        resets_at: numberOrNull(value.resets_at),
    };
}

function run() {
    const inputData = $.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile;
    const inputString = $.NSString.alloc.initWithDataEncoding(
        inputData,
        $.NSUTF8StringEncoding
    );
    if (!inputString) {
        throw new Error("statusLine input is not UTF-8");
    }

    const payload = JSON.parse(ObjC.unwrap(inputString));
    const limits = payload.rate_limits || {};
    const fiveHour = windowSnapshot(limits.five_hour);
    const sevenDay = windowSnapshot(limits.seven_day);
    const snapshot = {
        five_hour: fiveHour,
        seven_day: sevenDay,
        updated_at: Date.now() / 1000,
    };

    const fileManager = $.NSFileManager.defaultManager;
    const environment = $.NSProcessInfo.processInfo.environment;
    const overriddenHome = ObjC.unwrap(environment.objectForKey("RATE_GADGET_TEST_HOME"));
    const homeDirectory = typeof overriddenHome === "string" && overriddenHome.length > 0
        ? overriddenHome
        : ObjC.unwrap($.NSHomeDirectory());
    const outputDirectory = homeDirectory
        + "/Library/Application Support/RateGadget";
    const attributes = { NSFilePosixPermissions: 448 }; // 0700
    const createError = Ref();
    if (!fileManager.createDirectoryAtPathWithIntermediateDirectoriesAttributesError(
        outputDirectory,
        true,
        attributes,
        createError
    )) {
        throw new Error("cannot create RateGadget support directory");
    }

    const outputPath = outputDirectory + "/claude-rate.json";
    const output = JSON.stringify(snapshot);
    const outputString = $.NSString.alloc.initWithUTF8String(output);
    const writeError = Ref();
    if (!outputString.writeToFileAtomicallyEncodingError(
        outputPath,
        true,
        $.NSUTF8StringEncoding,
        writeError
    )) {
        throw new Error("cannot write Claude rate snapshot");
    }
    fileManager.setAttributesOfItemAtPathError(
        { NSFilePosixPermissions: 384 }, // 0600
        outputPath,
        Ref()
    );

    const labels = [];
    if (fiveHour) labels.push("5h:" + Math.round(fiveHour.used_percentage) + "%");
    if (sevenDay) labels.push("7d:" + Math.round(sevenDay.used_percentage) + "%");
    return labels.join(" ");
}
