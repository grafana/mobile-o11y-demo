<script lang="ts">
// biome-ignore assist/source/organizeImports: organized by hand
import { faro } from '@grafana/faro-web-sdk';
import {
	PUBLIC_BACKEND_ENDPOINT,
	PUBLIC_BACKEND_WS_ENDPOINT,
} from '$env/static/public';
import { onMount } from 'svelte';
import { Confetti } from 'svelte-confetti';
import { wsVisitorIDStore, userTokenStore } from '../lib/stores';
import ToggleConfetti from '../lib/ToggleConfetti.svelte';
// Track if Sentry is enabled (loaded from config)
let sentryEnabled = false;
let sentryDsn = '';

// All error types - backend (Go) and frontend (JS)
const errorTypes = [
	{ value: 'backend:panic', label: 'Backend: Panic', source: 'backend' },
	{ value: 'backend:error', label: 'Backend: Error', source: 'backend' },
	{ value: 'backend:context', label: 'Backend: Context', source: 'backend' },
	{ value: 'frontend:TypeError', label: 'Frontend: TypeError', source: 'frontend' },
	{ value: 'frontend:ReferenceError', label: 'Frontend: ReferenceError', source: 'frontend' },
	{ value: 'frontend:RangeError', label: 'Frontend: RangeError', source: 'frontend' },
];
let selectedErrorType = 'backend:panic';

// Check if Sentry is configured via backend config
async function checkSentryEnabled() {
	try {
		const res = await fetch(`${PUBLIC_BACKEND_ENDPOINT}/api/config`);
		const config = await res.json();
		sentryEnabled = !!config.sentry_dsn;
		sentryDsn = config.sentry_dsn || '';
	} catch {
		sentryEnabled = false;
		sentryDsn = '';
	}
}

// Send test error - routes to backend or frontend based on selection
async function sendTestError() {
	const [source, errorType] = selectedErrorType.split(':');
	
	if (source === 'backend') {
		await sendBackendError(errorType);
	} else {
		await sendFrontendError(errorType);
	}
}

// Send a test error to backend API
async function sendBackendError(errorType: string) {
	try {
		const response = await fetch(
			`${PUBLIC_BACKEND_ENDPOINT}/api/test-sentry-error?type=${errorType}`,
			{ method: 'GET' }
		);
		
		let responseData;
		try {
			responseData = await response.json();
		} catch {
			responseData = { message: 'Error sent to backend' };
		}
		
		if (response.status === 500 || response.ok) {
			faro.api.pushEvent('Test Error Sent', { 
				timestamp: new Date().toISOString(),
				errorType,
				source: 'backend',
			});
			alert(responseData.message || `Backend ${errorType} error sent! Check Grafault.`);
		} else {
			alert(`Failed: ${response.status} ${responseData.error || response.statusText}`);
		}
	} catch (error) {
		alert(`Failed: ${error instanceof Error ? error.message : 'Unknown error'}`);
	}
}

// Frontend error templates with hardcoded source locations
// These point to real file paths in the repository
const frontendErrorTemplates: Record<string, {
	type: string;
	message: string;
	frames: Array<{
		filename: string;
		function: string;
		lineno: number;
		colno: number;
		context_line: string;
		pre_context: string[];
		post_context: string[];
	}>;
}> = {
	TypeError: {
		type: 'TypeError',
		message: "Cannot read properties of null (reading 'userName') - QuickPizza frontend error",
		frames: [
			{
				filename: 'pkg/web/src/routes/+page.svelte',
				function: 'getUserDisplayName',
				lineno: 245,
				colno: 12,
				context_line: "    const displayName = user.profile.userName.toUpperCase();",
				pre_context: [
					"// Get user display name from profile",
					"function getUserDisplayName(user: User | null) {",
					"    // This will throw if user is null",
				],
				post_context: [
					"    return displayName;",
					"}",
					"",
				],
			},
			{
				filename: 'pkg/web/src/routes/+page.svelte',
				function: 'handlePizzaRequest',
				lineno: 312,
				colno: 8,
				context_line: "        const userName = getUserDisplayName(currentUser);",
				pre_context: [
					"async function handlePizzaRequest() {",
					"    try {",
					"        // Get user name for the request",
				],
				post_context: [
					"        await requestPizza(userName);",
					"    } catch (error) {",
					"        console.error('Failed to request pizza:', error);",
				],
			},
		],
	},
	ReferenceError: {
		type: 'ReferenceError',
		message: "pizzaConfig is not defined - QuickPizza frontend error",
		frames: [
			{
				filename: 'pkg/web/src/routes/+page.svelte',
				function: 'loadPizzaConfiguration',
				lineno: 178,
				colno: 15,
				context_line: "    const toppings = pizzaConfig.defaultToppings;",
				pre_context: [
					"// Load pizza configuration",
					"function loadPizzaConfiguration() {",
					"    // pizzaConfig should be defined but isn't",
				],
				post_context: [
					"    return { toppings, sauce: pizzaConfig.sauce };",
					"}",
					"",
				],
			},
			{
				filename: 'pkg/web/src/routes/+page.svelte',
				function: 'initializePizzaBuilder',
				lineno: 156,
				colno: 4,
				context_line: "    const config = loadPizzaConfiguration();",
				pre_context: [
					"",
					"async function initializePizzaBuilder() {",
					"    // Initialize the pizza builder with config",
				],
				post_context: [
					"    setPizzaDefaults(config);",
					"    return config;",
					"}",
				],
			},
		],
	},
	RangeError: {
		type: 'RangeError',
		message: "Maximum call stack size exceeded - QuickPizza frontend error",
		frames: [
			{
				filename: 'pkg/web/src/routes/+page.svelte',
				function: 'calculatePizzaPrice',
				lineno: 289,
				colno: 12,
				context_line: "    return calculatePizzaPrice(toppings); // Recursive call without base case",
				pre_context: [
					"// Calculate pizza price based on toppings",
					"function calculatePizzaPrice(toppings: string[]) {",
					"    // Bug: infinite recursion",
				],
				post_context: [
					"}",
					"",
					"// This function should have a base case",
				],
			},
			{
				filename: 'pkg/web/src/routes/+page.svelte',
				function: 'onPizzaSubmit',
				lineno: 425,
				colno: 8,
				context_line: "        const price = calculatePizzaPrice(selectedToppings);",
				pre_context: [
					"async function onPizzaSubmit() {",
					"    const selectedToppings = getSelectedToppings();",
					"    // Calculate the total price",
				],
				post_context: [
					"    await submitOrder(price);",
					"}",
					"",
				],
			},
		],
	},
};

// Send frontend error directly to Grafault with hardcoded source info
async function sendFrontendError(errorType: string) {
	if (!sentryDsn) {
		alert('Sentry DSN not configured');
		return;
	}

	const template = frontendErrorTemplates[errorType];
	if (!template) {
		alert(`Unknown error type: ${errorType}`);
		return;
	}

	try {
		// Parse DSN: http://token@host/stackId
		const dsnUrl = new URL(sentryDsn);
		const projectToken = dsnUrl.username;
		const host = dsnUrl.host;
		const stackId = dsnUrl.pathname.replace('/', '');

		if (!projectToken || !stackId) {
			alert('Invalid Sentry DSN format');
			return;
		}

		// Generate event ID
		const eventId = crypto.randomUUID().replace(/-/g, '');
		const timestamp = new Date();

		// Build envelope header
		const header = {
			event_id: eventId,
			sent_at: timestamp.toISOString(),
			sdk: { name: 'sentry.javascript.svelte', version: '9.47.1' },
			trace: { environment: 'development' },
		};

		// Build event data with hardcoded stack trace
		const eventData = {
			event_id: eventId,
			platform: 'javascript',
			timestamp: timestamp.getTime() / 1000,
			environment: 'development',
			release: '1.0.0',
			exception: [{
				type: template.type,
				value: template.message,
				stacktrace: {
					frames: template.frames.map(frame => ({
						filename: frame.filename,
						function: frame.function,
						lineno: frame.lineno,
						colno: frame.colno,
						in_app: true,
						context_line: frame.context_line,
						pre_context: frame.pre_context,
						post_context: frame.post_context,
					})),
				},
				mechanism: { type: 'generic', handled: true },
			}],
			sdk: {
				name: 'sentry.javascript.svelte',
				version: '9.47.1',
				integrations: ['BrowserTracing', 'Breadcrumbs'],
			},
			tags: {
				'service.name': 'quickpizza-frontend',
				'error.source': 'frontend-test-button',
				'error.type': errorType,
			},
			extra: {
				userTriggered: true,
				timestamp: timestamp.toISOString(),
				browser: navigator.userAgent,
			},
			contexts: {
				browser: {
					name: navigator.userAgent.includes('Chrome') ? 'Chrome' : 'Browser',
				},
			},
		};

		// Build envelope (newline-delimited JSON)
		const envelope = [
			JSON.stringify(header),
			JSON.stringify({ type: 'event' }),
			JSON.stringify(eventData),
		].join('\n');

		// Send to Grafault
		const endpoint = `${dsnUrl.protocol}//${host}/api/${stackId}/envelope/?sentry_key=${projectToken}`;
		const response = await fetch(endpoint, {
			method: 'POST',
			headers: {
				'Content-Type': 'application/x-sentry-envelope',
				'X-Sentry-Auth': `Sentry sentry_version=7, sentry_client=sentry.javascript.svelte/9.47.1, sentry_key=${projectToken}`,
			},
			body: envelope,
		});

		if (response.ok) {
			faro.api.pushEvent('Test Error Sent', {
				timestamp: timestamp.toISOString(),
				errorType,
				source: 'frontend',
			});
			alert(`Frontend ${errorType} sent to Grafault! Check errors list.`);
		} else {
			const text = await response.text();
			alert(`Failed to send error: ${response.status} ${text}`);
		}
	} catch (error) {
		alert(`Failed: ${error instanceof Error ? error.message : 'Unknown error'}`);
	}
}

const defaultRestrictions = {
	maxCaloriesPerSlice: 1000,
	mustBeVegetarian: false,
	excludedIngredients: [],
	excludedTools: [],
	maxNumberOfToppings: 5,
	minNumberOfToppings: 2,
	customName: '',
};

var ratingStars = 5;

// A randomly-generated integer used to track identity of WebSocket connections.
// Completely unrelated to users, user tokens, authentication, etc.
var wsVisitorID = 0;

// A randomly-generated user token that can be used to authenticate against the QP API.
// Since this token is not actually stored in the database, the returned user will always
// be user with ID 1 (default). This is implemented like so in order to not break the
// way QP was set up originally (i.e. one can open the website and start creating pizzas
// immediately, without logging in anywhere). So technically, the user is already logged
// in the moment they open the page.
// Additionally, if the qp_user_token Cookie has been set via the /login page, the value
// of the Cookie will take priority over this token sent over the Authorization header.
var userToken = '';

var render = false;
var quote = '';
var pizza = '';
var tools: string[] = [];
var pizzaCount = 0;
let restrictions = defaultRestrictions;
var advanced = false;
var rateResult = null;
var errorResult = null;

$: if (advanced) {
	pizza = '';
	restrictions = defaultRestrictions;
} else {
	pizza = '';
	restrictions = defaultRestrictions;
}

function randomToken(length) {
	let result = '';
	const characters =
		'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
	const charactersLength = characters.length;
	let counter = 0;
	while (counter < length) {
		result += characters.charAt(Math.floor(Math.random() * charactersLength));
		counter += 1;
	}
	return result;
}

let socket: WebSocket;
onMount(async () => {
	// Check if Sentry is enabled
	checkSentryEnabled();
	// biome-ignore lint/suspicious/noAssignInExpressions: -
	wsVisitorIDStore.subscribe((value) => (wsVisitorID = value));
	if (wsVisitorID === 0) {
		wsVisitorIDStore.set(Math.floor(100000 + Math.random() * 900000));
	}
	// biome-ignore lint/suspicious/noAssignInExpressions: -
	userTokenStore.subscribe((value) => (userToken = value));
	if (userToken === '') {
		userTokenStore.set(randomToken(16));
	}
	const res = await fetch(`${PUBLIC_BACKEND_ENDPOINT}/api/quotes`);
	const json = await res.json();
	quote = json.quotes[Math.floor(Math.random() * json.quotes.length)];

	let wsUrl = `${PUBLIC_BACKEND_WS_ENDPOINT}`;
	if (wsUrl === '') {
		// Unlike with fetch, which understands "/" as "the window's host", for WS we need to build the URI by hand.
		const l = window.location;
		wsUrl =
			(l.protocol === 'https:' ? 'wss://' : 'ws://') +
			l.hostname +
			(l.port !== 80 && l.port !== 443 ? ':' + l.port : '') +
			'/ws';
	}
	socket = new WebSocket(wsUrl);
	socket.addEventListener('message', function (event) {
		const data = JSON.parse(event.data);
		if (data.msg === 'new_pizza') {
			if (data.ws_visitor_id !== wsVisitorID) {
				pizzaCount++;
			}
		}
	});
	getTools();
	render = true;
	faro.api.pushEvent('Navigation', { url: window.location.href });
});

async function ratePizza(stars) {
	faro.api.pushEvent('Submit Pizza Rating', {
		pizza_id: pizza['pizza']['id'],
		stars: stars,
	});
	faro.api.startUserAction(
		'ratePizza', // name of the user action
		{ pizza_id: pizza['pizza']['id'], stars: stars }, // custom attributes attached to the user action
		{ triggerName: 'ratePizzaButtonClick' }, // custom config
	);
	const res = await fetch(`${PUBLIC_BACKEND_ENDPOINT}/api/ratings`, {
		method: 'POST',
		body: JSON.stringify({
			pizza_id: pizza['pizza']['id'],
			stars: stars,
		}),
		headers: {
			'Content-Type': 'application/json',
		},
	});
	if (res.ok) {
		rateResult = 'Rated!';
	} else {
		rateResult = 'Please log in first.';
		faro.api.pushError(new Error('Unauthenticated Ratings Submission'));
	}
}

async function getPizza() {
	faro.api.pushEvent('Get Pizza Recommendation', {
		restrictions: restrictions,
	});
	faro.api.startUserAction(
		'getPizza', // name of the user action
		{ restrictions: restrictions }, // custom attributes attached to the user action
		{ triggerName: 'getPizzaButtonClick' }, // custom config
	);
	if (restrictions.minNumberOfToppings > restrictions.maxNumberOfToppings) {
		faro.api.pushError(new Error('Invalid Restrictions, Min > Max'));
	}
	const res = await fetch(`${PUBLIC_BACKEND_ENDPOINT}/api/pizza`, {
		method: 'POST',
		body: JSON.stringify(restrictions),
		headers: {
			Authorization: 'Token ' + userToken,
			'Content-Type': 'application/json',
		},
	});
	const json = await res.json();

	rateResult = null;
	errorResult = null;
	if (!res.ok) {
		pizza = '';
		errorResult =
			json.error || 'Failed to get pizza recommendation. Please try again.';
		faro.api.pushError(new Error(errorResult));
		return;
	}

	pizza = json;
	const wsMsg = JSON.stringify({
		// FIXME: The 'user' key is present in order not to break
		// existing examples using QP WS. Remove it at some point.
		// It has no connection to the user auth itself.
		user: wsVisitorID,
		ws_visitor_id: wsVisitorID,
		msg: 'new_pizza',
	});
	if (socket.readyState === WebSocket.OPEN) {
		socket.send(wsMsg);
	} else if (socket.readyState === WebSocket.CONNECTING) {
		const handleOpen = () => {
			socket.send(wsMsg);
			socket.removeEventListener('open', handleOpen);
		};
		socket.addEventListener('open', handleOpen);
	} else {
		faro.api.pushError(new Error('socket state error: ' + socket.readyState));
	}

	if (pizza['pizza']['ingredients'].find((e) => e.name === 'Pineapple')) {
		faro.api.pushError(
			new Error(
				'Pizza Error: Pineapple detected! This is a violation of ancient pizza law. Proceed at your own risk!',
			),
		);
	}
}

async function getTools() {
	faro.api.pushEvent('Get Pizza Tools', { tools: tools });
	const res = await fetch(`${PUBLIC_BACKEND_ENDPOINT}/api/tools`, {
		headers: {
			Authorization: 'Token ' + userToken,
		},
	});
	const json = await res.json();
	tools = json.tools;
}
</script>

<svelte:head>
	<title>QuickPizza</title>
	<meta name="description" content="QuickPizza" />
</svelte:head>
{#if render}
	<section class="mt-4 flow-root">
		<div class="flex float-left">
			<a href="https://quickpizza.grafana.com"
				><img class="w-7 h-7 mr-2" src="/images/pizza.png" alt="logo" /></a
			>
			<p class="text-xl font-bold text-red-600">QuickPizza</p>
		</div>
		<div class="flex float-right">
			<span class="relative inline-flex items-center mb-5 mt-1 mr-6">
				<span class="ml-3 text-xs text-red-600 font-bold"
					><a data-sveltekit-reload href="/login">Login/Profile</a></span
				>
			</span>
			<label class="relative inline-flex items-center mb-5 cursor-pointer mt-1">
				<input type="checkbox" bind:checked={advanced} class="sr-only peer" />
				<div
					class="w-9 h-5 bg-gray-200 rounded-full peer dark:bg-gray-700 peer-checked:after:translate-x-full peer-checked:after:border-white after:content-[''] after:absolute after:top-[2px] after:left-[2px] after:bg-white after:border-gray-300 after:border after:rounded-full after:h-4 after:w-4 after:transition-all peer-checked:bg-red-600"
				/>
				<span class="ml-2 text-xs">Advanced</span>
			</label>
		</div>
	</section>
	<section class="mt-8 flex flex-row justify-center items-center">
		{#if quote}
			<br />
			<div class="bg-gray-50 border border-gray-200 rounded-lg p-2 text-sm">
				{quote}
			</div>
			<br />
		{/if}
	</section>
	<section class="mt-4 flex flex-column justify-center items-center">
		<div class="text-center">
			<h1 class="text-2xl md:text-4xl mt-14 font-semibold">
				Looking to break out of your pizza routine?
			</h1>
			<h2 class="text-xl md:text-2xl mt-2 font-semibold">
				<span class="text-red-600">QuickPizza</span> has your back!
			</h2>
			<p class="m-2 text-gray-700">
				With just one click, you'll discover new and exciting pizza combinations that you never knew
				existed.
			</p>
			{#if advanced}
				<div class="mt-6 mb-2 bg-gray-50 border border-gray-200 rounded-lg p-4">
					<div class="flex flex-row">
						<div class="relative">
							<input
								bind:value={restrictions.maxCaloriesPerSlice}
								type="number"
								id="floating_filled"
								class="block rounded-t-lg px-2.5 pb-2.5 pt-5 w-full text-sm text-gray-900 bg-gray-50 border-0 border-b-2 border-gray-300 appearance-none focus:outline-none focus:ring-0 focus:border-red-600 peer"
								placeholder=" "
							/>
							<label
								for="floating_filled"
								class="absolute text-sm text-gray-900 duration-300 transform -translate-y-4 scale-75 top-4 z-10 origin-[0] left-2.5 peer-focus:text-red-600 peer-focus:dark:text-blue-500 peer-placeholder-shown:scale-100 peer-placeholder-shown:translate-y-0 peer-focus:scale-75 peer-focus:-translate-y-4"
								>Max Calories per Slice</label
							>
						</div>
						<div class="relative ml-2">
							<input
								bind:value={restrictions.minNumberOfToppings}
								type="number"
								id="floating_filled"
								class="block rounded-t-lg px-2.5 pb-2.5 pt-5 w-full text-sm text-gray-900 bg-gray-50 border-0 border-b-2 border-gray-300 appearance-none focus:outline-none focus:ring-0 focus:border-red-600 peer"
								placeholder=" "
							/>
							<label
								for="floating_filled"
								class="absolute text-sm text-gray-900 duration-300 transform -translate-y-4 scale-75 top-4 z-10 origin-[0] left-2.5 peer-focus:text-red-600 peer-focus:dark:text-blue-500 peer-placeholder-shown:scale-100 peer-placeholder-shown:translate-y-0 peer-focus:scale-75 peer-focus:-translate-y-4"
								>Min Number of Toppings</label
							>
						</div>
						<div class="relative ml-2">
							<input
								bind:value={restrictions.maxNumberOfToppings}
								type="number"
								id="floating_filled"
								class="block rounded-t-lg px-2.5 pb-2.5 pt-5 w-full text-sm text-gray-900 bg-gray-50 border-0 border-b-2 border-gray-300 appearance-none focus:outline-none focus:ring-0 focus:border-red-600 peer"
								placeholder=" "
							/>
							<label
								for="floating_filled"
								class="absolute text-sm text-gray-900 duration-300 transform -translate-y-4 scale-75 top-4 z-10 origin-[0] left-2.5 peer-focus:text-red-600 peer-focus:dark:text-blue-500 peer-placeholder-shown:scale-100 peer-placeholder-shown:translate-y-0 peer-focus:scale-75 peer-focus:-translate-y-4"
								>Max Number of Toppings</label
							>
						</div>
					</div>
					<div class="flex mt-8 justify-center items-center">
						<div>
							<label for="countries_multiple" class="block text-sm text-gray-900"
								>Excluded tools</label
							>
							<select
								multiple
								bind:value={restrictions.excludedTools}
								class="bg-gray-50 ml-4 border border-gray-300 text-gray-900 text-sm rounded-lg block p-2.5"
							>
								{#each tools as t}
									<option value={t}>
										{t}
									</option>
								{/each}
							</select>
						</div>
						<div class="flex items-center ml-16">
							<input
								id="default-checkbox"
								bind:checked={restrictions.mustBeVegetarian}
								type="checkbox"
								value=""
								class="w-4 h-4 text-red-600 bg-gray-100 border-gray-300 rounded accent-red-600"
							/>
							<label for="default-checkbox" class="ml-2 text-sm text-gray-900"
								>Must be vegetarian</label
							>
						</div>
					</div>
					<div class="flex mt-8 justify-center items-center">
						<div clas="flex items-center ml-16">
							<label for="pizza-name" class="ml-2 text-sm text-gray-900">Custom Pizza Name:</label>
							<input
								id="pizza-name"
								bind:value={restrictions.customName}
								class="h-6 bg-gray-200 border-gray-900 rounded accent-red-600"
							/>
						</div>
					</div>
				</div>
			{/if}
			<ToggleConfetti>
				<button
					slot="label"
					type="button"
					name="pizza-please"
					on:click={getPizza}
					class="mt-6 text-white bg-gradient-to-br from-red-500 to-orange-400 hover:bg-gradient-to-bl font-medium rounded-lg text-sm px-5 py-2.5 text-center mr-2 mb-2"
				>
					Pizza, Please!</button
				>
				<Confetti
					y={[-0.5, 0.5]}
					x={[-0.5, 0.5]}
					size="30"
					amount="10"
					colorArray={['url(/images/pizza.png)']}
				/>
			</ToggleConfetti>
			<p />
			{#if errorResult}
				<div class="mt-4">
					<span class="bg-red-100 text-red-800 text-sm font-medium mr-2 px-2.5 py-0.5 rounded" id="error-message"
						>{errorResult}</span
					>
				</div>
			{/if}
			{#if pizzaCount > 0 && !pizza['pizza']}
				<div class="mt-4">
					<span class="bg-purple-100 text-purple-800 text-sm font-medium mr-2 px-2.5 py-0.5 rounded"
						>What are you waiting for? We have already given {pizzaCount} recommendations since you opened
						the site!</span
					>
				</div>
			{/if}
			<p>
				{#if pizza['pizza']}
					<div class="flex justify-center" id="recommendations">
						<div class="w-[300px] sm:w-[500px] mt-6 bg-gray-50 border border-gray-200 rounded-lg">
							<div class="text-left p-4">
								<h2 class="font-medium" id="pizza-name">Our recommendation:</h2>
								<div class="ml-2">
									<p>Name: {pizza['pizza']['name']}</p>
									<p>Dough: {pizza['pizza']['dough']['name']}</p>
									<p>Ingredients:</p>
									<ul class="list-disc list-inside">
										{#each pizza['pizza']['ingredients'] as ingredient}
											<li class="pl-5 list-inside">{ingredient['name']}</li>
										{/each}
									</ul>
									<p>Tool: {pizza['pizza']['tool']}</p>
									<p>Calories per slice: {pizza['calories']}</p>
								</div>
							</div>
						</div>
					</div>
					<button
						type="button"
						name="rate-1"
						on:click={() => ratePizza(1)}
						class="mt-6 text-white bg-gray-400 font-medium rounded-lg text-sm px-4 py-1.5 text-center mr-2 mb-2"
					>
						No thanks</button
					>
					<button
						type="button"
						name="rate-5"
						on:click={() => ratePizza(5)}
						class="mt-6 text-white bg-red-400 font-medium rounded-lg text-sm px-4 py-1.5 text-center mr-2 mb-2"
					>
						Love it!</button
					>
					{#if rateResult}
						<p class="text-base mt-1 font-bold" id="rate-result">{rateResult}</p>
					{/if}
				{/if}
			</p>
		</div>
	</section>
	<footer>
		<div class="flex justify-center mt-8 m-1">
			<p class="text-sm">Made with ❤️ by QuickPizza Labs.</p>
		</div>
		<div class="flex justify-center">
			<p class="text-xs">WebSocket visitor ID: {wsVisitorID}</p>
		</div>
		<div class="flex justify-center">
			<p class="text-xs">
				Looking for the admin page? <a class="text-blue-500" data-sveltekit-reload href="/admin"
					>Click here</a
				>
			</p>
		</div>
		<div class="flex justify-center">
			<p class="text-xs">
				Contribute to QuickPizza on <a
					class="text-blue-500"
					href="https://github.com/grafana/quickpizza">GitHub</a
				>
			</p>
		</div>
	{#if sentryEnabled}
		<div class="flex justify-center items-center mt-4 gap-2">
			<select
				bind:value={selectedErrorType}
				class="bg-gray-50 border border-gray-300 text-gray-900 text-xs rounded-lg px-2 py-1.5"
			>
				{#each errorTypes as errorType}
					<option value={errorType.value}>{errorType.label}</option>
				{/each}
			</select>
			<button
				type="button"
				on:click={sendTestError}
				class="text-white bg-purple-600 hover:bg-purple-700 font-medium rounded-lg text-xs px-3 py-1.5 text-center"
				title="Send test error to Grafault"
			>
				🐛 Test Error
			</button>
		</div>
	{/if}
	</footer>
{/if}
