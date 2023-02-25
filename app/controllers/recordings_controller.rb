class RecordingsController < ApplicationController
	# Global mutex to lock when performing any write operations
	@@lock = Mutex.new

	@@camera_mgr_address = "clustervms.localdomain"
	@@moonfire_address = "moonfire.localdomain"

	def index
		# Get the latest data for that camera and stream (or all streams/cameras if the request didn't specify)
		refreshCameras(params[:camera], params[:stream])

		recordings = Recording.select(:id, :run_id, :camera, :stream, :start_time, :end_time, :moonfire_id, :moonfire_camera_id).order(:camera, :stream, :run_id, :start_time)

		if params[:camera]
			recordings = recordings.where(camera: params[:camera])
		end
		if params[:stream]
			recordings = recordings.where(stream: params[:stream])
		end

		# Aggregate contiguous recording segments
		aggregations = []
		curr_agg = Hash.new
		moonfire_camera_id = nil
		moonfire_id_start = nil
		moonfire_id_end = nil
		run_id = nil
		recordings.each{ |rec|
			if
				curr_agg.empty? ||
				curr_agg[:end_time] != rec["start_time"] ||
				curr_agg[:camera] != rec["camera"] ||
				curr_agg[:stream] != rec["stream"] ||
				run_id != rec["run_id"]
			then
				# Create new entry
				if !curr_agg.empty?
					# Append the previous entry
					curr_agg[:url] = "http://#{@@moonfire_address}/api/cameras/#{moonfire_camera_id}/main/view.mp4?s=#{moonfire_id_start}-#{moonfire_id_end}"
					aggregations.append(curr_agg)
				end
				curr_agg = Hash.new
				curr_agg[:camera] = rec["camera"]
				curr_agg[:stream] = rec["stream"]
				curr_agg[:start_time] = rec["start_time"]
				run_id = rec["run_id"]
				moonfire_id_start = rec["moonfire_id"]
				moonfire_camera_id = rec["moonfire_camera_id"]
			end
			moonfire_id_end = rec["moonfire_id"]
			curr_agg[:end_time] = rec["end_time"]
		}

		# Append the last entry if we actually have any data (if no records found, we'll have an empty curr_agg object at this point)
		if curr_agg.has_key?(:start_time)
			curr_agg[:url] = "http://#{@@moonfire_address}/api/cameras/#{moonfire_camera_id}/main/view.mp4?s=#{moonfire_id_start}-#{moonfire_id_end}"
			aggregations.append(curr_agg)
		end

		render json: aggregations
	end

	def refreshCameras(cameraId = nil, streamId = nil)
		if cameraId && streamId
			# Only refresh that stream
			url = "http://#{@@camera_mgr_address}/v0/cameras/#{cameraId}/streams/#{streamId}"
			response = Faraday.get(url)
			stream = JSON.parse(response.body, symbolize_names: true)
			if stream.has_key?(:labels) && stream[:labels].has_key?(:moonfire_camera_id)
				refreshMoonfire(cameraId, streamId, stream[:labels][:moonfire_camera_id])
			else
				print "Stream #{streamId} is missing the moonfire_camera_id label"
			end
		elsif cameraId
			# Only refresh that camera
			url = "http://#{@@camera_mgr_address}/v0/cameras/#{cameraId}"
			response = Faraday.get(url)
			camera = JSON.parse(response.body, symbolize_names: true)
			camera[:streams].each{ |stream_id, stream|
				if stream.has_key?(:labels) && stream[:labels].has_key?(:moonfire_camera_id)
					refreshMoonfire(cameraId, stream_id, stream[:labels][:moonfire_camera_id])
				end
			}
		else
			# Refresh all cameras
			url = "http://#{@@camera_mgr_address}/v0/cameras/?format=full"
			response = Faraday.get(url)
			res_json = JSON.parse(response.body, symbolize_names: true)

			res_json.each{ |camera|
				camera[:streams].each{ |stream_id, stream|
					if stream.has_key?(:labels) && stream[:labels].has_key?(:moonfire_camera_id)
						refreshMoonfire(camera[:id], stream_id, stream[:labels][:moonfire_camera_id])
					end
				}
			}
		end
	end

	def refreshMoonfire(cameraId, streamId, moonfire_camera_id)
		# Lock to prevent time-of-check to time-of-use error
		# Without locking, two threads could try to add the same missing entries, leading to duplicate entries
		@@lock.synchronize {
			url = "http://#{@@moonfire_address}/api/cameras/#{moonfire_camera_id}/main/recordings?split90k=1"
			response = Faraday.get(url)
			res_json = JSON.parse(response.body, symbolize_names: true)

			current_moonfire_rec_ids = res_json[:recordings].collect{|r| r[:startId]}.to_set
			known_moonfire_rec_ids = Recording.where(moonfire_camera_id: moonfire_camera_id).pluck(:moonfire_id).to_set

			# Remove entries for recordings that have been deleted
			deleted_moonfire_ids = known_moonfire_rec_ids - current_moonfire_rec_ids
			Recording.destroy_by(moonfire_id: deleted_moonfire_ids)

			res_json[:recordings]
				# Filter out any recordings we already have
				.filter{ |recording| !known_moonfire_rec_ids.include?(recording[:startId]) }
				# Filter out any recordings that are still growing.
				# Just a temporary hack to simplify initial implementation (this way we don't need to worry about updating the entry later)
				.filter{ |recording| !recording[:growing] }
				.map{ |moonfire_data|
					entry = Recording.new(moonfire_id: moonfire_data[:startId], camera: cameraId, stream: streamId, moonfire_camera_id: moonfire_camera_id, run_id: moonfire_data[:openId], start_time: moonfire_data[:startTime90k], end_time: moonfire_data[:endTime90k])
					entry.save
				}
		}
	end
end
