//
//  SceneDelegate.swift
//  Voice Notes
//
//  Created by Bhavesh on 11/10/25.
//

import UIKit
import AVFoundation
import FirebaseStorage
import FirebaseFirestore

class ViewController: UIViewController {
    
    // MARK: - Outlets
    @IBOutlet weak var recordButton: UIButton!
    @IBOutlet weak var timerLabel: UILabel!
    @IBOutlet weak var recordingsTableView: UITableView!
    
    // MARK: - Properties
    private var audioRecorder: AVAudioRecorder?
    private var audioPlayer: AVAudioPlayer?
    private var isRecording = false
    private var timer: Timer?
    private var recordingTime: TimeInterval = 0
    private var recordings: [Recording] = []
    private var currentRecordingURL: URL?
    private var uploadTask: StorageUploadTask?
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
    
    // User ID - using device identifier or generating one
    private var userId: String {
        if let savedUserId = UserDefaults.standard.string(forKey: "firebase_user_id") {
            return savedUserId
        } else {
            let newUserId = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
            UserDefaults.standard.set(newUserId, forKey: "firebase_user_id")
            return newUserId
        }
    }
    
    // MARK: - Lifecycle Methods
    override func viewDidLoad() {
        super.viewDidLoad()
        
        setupUI()
        setupTableView()
        loadRecordings()
        requestMicrophonePermission()
    }
    
    // MARK: - Setup Methods
    private func setupUI() {
        // Reset timer label
        timerLabel.text = formatTimeInterval(0)
        
        // Configure record button
        recordButton.layer.cornerRadius = recordButton.bounds.height / 2
    }
    
    private func setupTableView() {
        recordingsTableView.delegate = self
        recordingsTableView.dataSource = self
    }
    
    private func requestMicrophonePermission() {
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                if !granted {
                    self?.showAlert(title: "Microphone Access Denied", message: "Please enable microphone access in Settings to use voice recording.")
                }
            }
        }
    }
    
    // MARK: - IBActions
    @IBAction func recordButtonTapped(_ sender: UIButton) {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }
    
    // MARK: - Recording Methods
    private func startRecording() {
        let audioSession = AVAudioSession.sharedInstance()
        
        do {
            try audioSession.setCategory(.playAndRecord, mode: .default)
            try audioSession.setActive(true)
            
            let documentPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let fileName = "recording_\(Date().timeIntervalSince1970).m4a"
            let fileURL = documentPath.appendingPathComponent(fileName)
            
            let settings = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            
            audioRecorder = try AVAudioRecorder(url: fileURL, settings: settings)
            audioRecorder?.delegate = self
            audioRecorder?.prepareToRecord()
            audioRecorder?.record()
            
            // Store the current recording URL
            currentRecordingURL = fileURL
            
            isRecording = true
            recordButton.setTitle("Stop", for: .normal)
            recordButton.backgroundColor = .systemBlue
            
            // Start timer
            recordingTime = 0
            timer = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(updateTimer), userInfo: nil, repeats: true)
            
        } catch {
            showAlert(title: "Recording Failed", message: "There was an error starting the recording: \(error.localizedDescription)")
        }
    }
    
    private func stopRecording() {
        guard let recordingURL = currentRecordingURL else {
            return
        }
        
        let duration = recordingTime
        audioRecorder?.stop()
        audioRecorder = nil
        
        timer?.invalidate()
        timer = nil
        
        isRecording = false
        recordButton.setTitle("Record", for: .normal)
        recordButton.backgroundColor = .systemRed
        
        // Get the custom name for the recording (or use default)
        let fileName = recordingURL.deletingPathExtension().lastPathComponent
        let customName = UserDefaults.standard.string(forKey: "customName_\(fileName)") ?? "Recording \(dateFormatter.string(from: Date()))"
        
        // Upload to Firebase
        uploadRecordingToFirebase(fileURL: recordingURL, title: customName, duration: duration)
        
        loadRecordings()
    }
    
    // MARK: - Timer Methods
    @objc private func updateTimer() {
        recordingTime += 1
        timerLabel.text = formatTimeInterval(recordingTime)
    }
    
    private func formatTimeInterval(_ interval: TimeInterval) -> String {
        let hours = Int(interval) / 3600
        let minutes = Int(interval) / 60 % 60
        let seconds = Int(interval) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
    
    // MARK: - Recording Management
    private func loadRecordings() {
        recordings.removeAll()
        
        let documentPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        
        do {
            let directoryContents = try FileManager.default.contentsOfDirectory(at: documentPath, includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey], options: [])
            
            let audioFiles = directoryContents.filter { $0.pathExtension == "m4a" }
            
            for fileURL in audioFiles {
                let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
                let creationDate = attributes[.creationDate] as? Date ?? Date()
                
                // Get custom name from UserDefaults if exists, otherwise use filename
                let fileName = fileURL.deletingPathExtension().lastPathComponent
                let customName = UserDefaults.standard.string(forKey: "customName_\(fileName)") ?? fileName
                
                let recording = Recording(url: fileURL, date: creationDate, customName: customName)
                recordings.append(recording)
            }
            
            recordings.sort { $0.date > $1.date }
            recordingsTableView.reloadData()
            
        } catch {
            showAlert(title: "Error", message: "Could not load recordings: \(error.localizedDescription)")
        }
    }
    
    private func playRecording(at url: URL) {
        do {
            // Stop any currently playing audio
            audioPlayer?.stop()
            
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.delegate = self
            audioPlayer?.prepareToPlay()
            audioPlayer?.play()
            
        } catch {
            showAlert(title: "Playback Error", message: "Cannot play the recording: \(error.localizedDescription)")
        }
    }
    
    private func deleteRecording(at index: Int) {
        let recording = recordings[index]
        
        do {
            try FileManager.default.removeItem(at: recording.url)
            
            // Remove custom name from UserDefaults if exists
            let fileName = recording.url.deletingPathExtension().lastPathComponent
            UserDefaults.standard.removeObject(forKey: "customName_\(fileName)")
            
            recordings.remove(at: index)
            recordingsTableView.deleteRows(at: [IndexPath(row: index, section: 0)], with: .fade)
            
        } catch {
            showAlert(title: "Delete Error", message: "Could not delete recording: \(error.localizedDescription)")
        }
    }
    
    private func renameRecording(at index: Int) {
        let recording = recordings[index]
        let fileName = recording.url.deletingPathExtension().lastPathComponent
        
        let alertController = UIAlertController(title: "Rename Recording", message: "Enter a new name for this recording", preferredStyle: .alert)
        
        alertController.addTextField { textField in
            textField.text = recording.customName
            textField.placeholder = "Enter name"
            textField.autocapitalizationType = .sentences
        }
        
        let cancelAction = UIAlertAction(title: "Cancel", style: .cancel)
        
        let saveAction = UIAlertAction(title: "Save", style: .default) { [weak self] _ in
            guard let self = self,
                  let textField = alertController.textFields?.first,
                  let newName = textField.text,
                  !newName.isEmpty else { return }
            
            // Store the custom name in UserDefaults
            UserDefaults.standard.set(newName, forKey: "customName_\(fileName)")
            
            // Update the recording in our array
            self.recordings[index].customName = newName
            
            // Reload the specific row
            self.recordingsTableView.reloadRows(at: [IndexPath(row: index, section: 0)], with: .automatic)
        }
        
        alertController.addAction(cancelAction)
        alertController.addAction(saveAction)
        
        present(alertController, animated: true)
    }
    
    private func showOptionsMenu(for recording: Recording, at indexPath: IndexPath) {
        let alertController = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        
        // Play option
        let playAction = UIAlertAction(title: "Play", style: .default) { [weak self] _ in
            self?.playRecording(at: recording.url)
        }
        
        // Rename option
        let renameAction = UIAlertAction(title: "Rename", style: .default) { [weak self] _ in
            self?.renameRecording(at: indexPath.row)
        }
        
        // Delete option
        let deleteAction = UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            self?.deleteRecording(at: indexPath.row)
        }
        
        // Cancel option
        let cancelAction = UIAlertAction(title: "Cancel", style: .cancel)
        
        alertController.addAction(playAction)
        alertController.addAction(renameAction)
        alertController.addAction(deleteAction)
        alertController.addAction(cancelAction)
        
        // For iPad support
        if let popoverController = alertController.popoverPresentationController {
            popoverController.sourceView = recordingsTableView.cellForRow(at: indexPath)
            popoverController.sourceRect = CGRect(x: recordingsTableView.cellForRow(at: indexPath)!.bounds.width - 40,
                                                 y: recordingsTableView.cellForRow(at: indexPath)!.bounds.height / 2,
                                                 width: 0, height: 0)
            popoverController.permittedArrowDirections = .any
        }
        
        present(alertController, animated: true)
    }
    
    // MARK: - Firebase Upload Methods
    private func uploadRecordingToFirebase(fileURL: URL, title: String, duration: TimeInterval) {
        // Show upload indicator
        DispatchQueue.main.async { [weak self] in
            self?.recordButton.setTitle("Uploading...", for: .normal)
            self?.recordButton.isEnabled = false
        }
        
        Task {
            do {
                // Upload to Firebase Storage and save metadata to Firestore
                let documentId = try await RecordingUploader.uploadAndSave(
                    fileURL: fileURL,
                    title: title,
                    duration: duration,
                    userId: userId
                )
                
                // Success - update UI on main thread
                await MainActor.run {
                    self.recordButton.setTitle("Record", for: .normal)
                    self.recordButton.isEnabled = true
                    self.showAlert(title: "Upload Successful", message: "Your recording has been saved to Firebase!")
                }
                
                print("✅ Recording uploaded successfully with ID: \(documentId)")
                
            } catch {
                // Error - show alert and re-enable button
                await MainActor.run {
                    self.recordButton.setTitle("Record", for: .normal)
                    self.recordButton.isEnabled = true
                    self.showAlert(title: "Upload Failed", message: "Could not upload recording to Firebase: \(error.localizedDescription)")
                }
                
                print("❌ Error uploading recording: \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - Helper Methods
    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

// MARK: - UITableViewDelegate, UITableViewDataSource
extension ViewController: UITableViewDelegate, UITableViewDataSource {
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return recordings.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "RecordingCell", for: indexPath)
        
        let recording = recordings[indexPath.row]
        
        cell.textLabel?.text = recording.customName
        cell.detailTextLabel?.text = dateFormatter.string(from: recording.date)
        
        // Add a more options button
        let moreButton = UIButton(type: .system)
        moreButton.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        moreButton.tag = indexPath.row
        moreButton.addTarget(self, action: #selector(moreButtonTapped(_:)), for: .touchUpInside)
        
        // Create a container for the button to adjust its position
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        moreButton.frame = CGRect(x: 0, y: 0, width: 40, height: 40)
        container.addSubview(moreButton)
        
        cell.accessoryView = container
        
        return cell
    }
    
    @objc func moreButtonTapped(_ sender: UIButton) {
        let index = sender.tag
        let recording = recordings[index]
        let indexPath = IndexPath(row: index, section: 0)
        
        showOptionsMenu(for: recording, at: indexPath)
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        
        let recording = recordings[indexPath.row]
        playRecording(at: recording.url)
    }
    
    // We'll keep the swipe-to-delete functionality too
    func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        if editingStyle == .delete {
            deleteRecording(at: indexPath.row)
        }
    }
}

// MARK: - AVAudioRecorderDelegate, AVAudioPlayerDelegate
extension ViewController: AVAudioRecorderDelegate, AVAudioPlayerDelegate {
    
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if !flag {
            stopRecording()
            showAlert(title: "Recording Failed", message: "The recording could not be saved.")
        }
    }
    
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        // Player finished - could add UI updates here if needed
    }
}

// MARK: - Recording Model
struct Recording {
    let url: URL
    let date: Date
    var customName: String
}
