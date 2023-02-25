Rails.application.routes.draw do
	get "/v0/recordings", to: "recordings#index"
end
